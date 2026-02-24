# DX/VPN Traffic Mirroring 监控系统 — 设计文档

## 一、设计目标

- **秒级实时**：5s 聚合窗口识别 Top Talker
- **不依赖托管监控**：不靠 VPC Flow Logs / CloudWatch 做定位
- **可执行告警**：消息直接给出 Top 源 IP/实例 + Top 目的端口 + Top 5-tuple
- **水平扩展**：每 AZ 独立 Probe 实例，多进程 SO_REUSEPORT 并行处理
- **高性能**：C 解析器 10x 加速，确定性采样支撑高流量场景

---

## 二、总体架构

```
On-Prem (172.16.0.0/12, 192.168.0.0/16)
  │ VPN / Direct Connect
  v
VGW (vgw-xxx)
  │ Ingress Route Table (edge association)
  │   dest: 业务子网 CIDR → next-hop: GWLBE
  v
GWLBE (每 AZ 一个, GWLBE_SUBNETS)
  │ VPC Endpoint Service
  v
GWLB (internal, Geneve UDP 6081)
  │ Target Group
  v
Appliance 实例 (c6g.large, WORKLOAD_SUBNETS, 每 AZ ≥1)
  │ 透传转发 → 业务子网
  │
  │ ← Traffic Mirror Session (source: appliance ENI)
  │    VNI=12345, packet-length=128
  v
NLB (internal, UDP 4789, cross-zone)      ← Mirror Target
  │ Target Group
  v
Probe 实例 (c6gn.2xlarge, WORKLOAD_SUBNETS, 每 AZ ≥1)
  │ SO_REUSEPORT 多进程绑定 UDP/4789
  │ VXLAN 解封装 → 5s 聚合 → Top-N 报告
  v
告警输出: SNS (SMS/Email) + Slack Webhook
```

### 流量路径

1. On-prem 流量经 VPN/DX 到达 VGW
2. VGW Ingress Route Table 将业务子网流量导向 GWLBE
3. GWLBE → GWLB → Appliance 实例（Geneve 封装）
4. Appliance 透传到业务子网
5. Appliance ENI 作为 Mirror Session 源，VXLAN 封装镜像到 NLB
6. NLB 分发到 Probe 实例，Probe 解封装并聚合分析

### 方案选择：VGW Ingress Routing + GWLB（B1）

| 方案 | 优点 | 缺点 |
|------|------|------|
| B1: VGW → GWLBE → Appliance | ENI 数量少、易管理；镜像 session 数可控 | 改变流量路径 |
| B2: 分散镜像业务 ENI | 不改路径 | session 数爆炸；ASG 扩缩容需自动跟进 |

B1 将入口流量集中到少量 Appliance ENI，与 TGW Attachment ENI 镜像思路一致，运维成本最低。

---

## 三、部署脚本流水线

```
00-init-config          验证 AWS 凭证、VPC、VGW；解析 AL2023 ARM64 AMI
        │
01-security-groups      创建 dx-appliance-sg + dx-probe-sg
        │
   ┌────┴────┐
   │         │          (可并行)
02-gwlb     04-probe
appliance   instances
   │         │
03-vgw      05-nlb
ingress     mirror-target
routing      │
   │    06-mirror-filter
   │         │
   └────┬────┘
        │
07-mirror-sessions      Appliance ENI → NLB Mirror Target
        │
08-probe-deploy         SCP + pip install + systemd 服务
        │
09-verify               5 阶段验证
        │
10-eni-lifecycle        Cron 自动同步 Mirror Session (可选)
```

### 脚本清单

| 脚本 | 功能 | 幂等机制 |
|------|------|----------|
| `00-init-config.sh` | 验证配置、解析 AMI、生成 `env-vars.sh` | Name tag 查重 |
| `01-security-groups.sh` | Appliance SG (UDP 6081) + Probe SG (UDP 4789) | 按 Name 复用 |
| `02-gwlb-appliance.sh` | Appliance 实例 + GWLB + Endpoint Service + GWLBE | check_var_exists |
| `03-vgw-ingress-routing.sh` | VGW Ingress Route Table + Edge Association + 路由 | check_var_exists |
| `04-probe-instances.sh` | Probe 实例 + IAM Role/Profile + 内核调优 | check_var_exists |
| `05-nlb-mirror-target.sh` | NLB (UDP/4789) + Target Group + Mirror Target | check_var_exists |
| `06-mirror-filter.sh` | ACCEPT on-prem ↔ VPC, REJECT fallback | check_var_exists |
| `07-mirror-sessions.sh` | 为每个 Appliance ENI 创建 Mirror Session | ENI 枚举去重 |
| `08-probe-deploy.sh` | SSH 部署 probe 代码、依赖、systemd 服务 | systemctl restart |
| `09-verify.sh` | 基础设施 → 路由 → Mirror → Probe → VXLAN 流量 | 只读检查 |
| `10-eni-lifecycle.sh` | Cron (2min): 新 ENI 建 session，下线 ENI 删 session | 增量同步 |
| `99-cleanup.sh` | 反序删除全部资源 | 需 `--force` 确认 |

### 共享函数库 (`scripts/lib/common.sh`)

- `load_config` / `load_env`: 加载配置和运行时变量
- `save_var` / `check_var_exists`: 持久化/检查资源 ID
- `wait_until`: 带超时的状态轮询
- `tag_resource`: 统一打 PROJECT_TAG

---

## 四、Probe 探针架构

### 4.1 多进程设计 (`multiproc_probe.py`)

```
                    ┌─────────────────────────────────┐
                    │          Coordinator             │
                    │  - 每 5s 从各 Worker Queue 汇总  │
                    │  - 按采样率放大流量计数          │
                    │  - 输出 Top-N 报告              │
                    │  - 触发 Alerter                  │
                    └────────┬──────────────────────────┘
                             │ multiprocessing.Queue
              ┌──────────────┼──────────────────┐
              v              v                  v
        ┌──────────┐  ┌──────────┐       ┌──────────┐
        │ Worker 0 │  │ Worker 1 │  ...  │ Worker N │
        │ bind()   │  │ bind()   │       │ bind()   │
        │ UDP 4789 │  │ UDP 4789 │       │ UDP 4789 │
        │ REUSEPORT│  │ REUSEPORT│       │ REUSEPORT│
        └──────────┘  └──────────┘       └──────────┘
              ↑              ↑                  ↑
              └──────────────┼──────────────────┘
                    Kernel SO_REUSEPORT 负载均衡
                             ↑
                        UDP/4789 (VXLAN)
```

核心设计：
- **SO_REUSEPORT**：多进程绑定同一端口，内核按 4-tuple hash 分发，无用户态锁
- **Worker 数 = CPU 核数**：`PROBE_WORKERS=0` 时自动检测
- **独立 FlowAggregator**：每个 Worker 维护独立流表，零跨进程共享
- **Queue 汇总**：Coordinator 每 5s 收集并合并所有 Worker 流数据

### 4.2 VXLAN 解析

| 实现 | 文件 | 性能 | 场景 |
|------|------|------|------|
| C 解析器 | `fast_parse.c` → `fast_parse.so` | 生产 | 唯一引擎 |
| C 收包引擎 | `fast_recv.c` → `fast_recv.so` | 生产 | recvmmsg 批量收包 |

C 解析器通过 `ctypes` 加载，解析流程：
```
VXLAN Header (8B) → Ethernet (14B) → IPv4 (20B+) → TCP/UDP Ports
```

### 4.3 流采样

Hash 确定性采样：同一 5-tuple 始终被采样或跳过。

```python
flow_key = f”{src}:{dst}:{proto}:{sport}:{dport}”
sampled = (hash(flow_key) % 10000) / 10000.0 < PROBE_SAMPLE_RATE
```

- `PROBE_SAMPLE_RATE=1.0`：全量（默认）
- `PROBE_SAMPLE_RATE=0.5`：50% 采样，报告时 ×2 放大

### 4.4 IP 富化 (`enricher.py`)

后台线程每 60s 调用 `DescribeInstances`：
```
私网 IP → { instance_id, name, asg, owner_tag }
```
线程安全（Lock），API 失败保留旧缓存。

### 4.5 告警 (`alerter.py`)

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ALERT_THRESHOLD_BPS` | 1 Gbps | 带宽阈值 |
| `ALERT_THRESHOLD_PPS` | 500K pps | 包速率阈值 |
| 冷却时间 | 300s | 防止告警风暴 |

通道：SNS (SMS/Email) + Slack Webhook
内容：Top 5 源 IP/目标 IP/5-tuple + 实例名/ASG/Owner

---

## 五、安全组设计

| 安全组 | 入站 | 出站 |
|--------|------|------|
| `dx-appliance-sg` | UDP 6081 (Geneve) from VPC; SSH from ADMIN | All to VPC |
| `dx-probe-sg` | UDP 4789 (VXLAN) from VPC; TCP 22 from VPC+ADMIN | TCP 443 (AWS API); All to VPC |

Probe SG 放行 TCP/22 from VPC_CIDR 用于 NLB 健康检查。

---

## 六、Mirror Filter 设计

最小化镜像量：

| 方向 | 规则 | 源 | 目标 |
|------|------|----|------|
| Inbound | ACCEPT 100 | 172.16.0.0/12 | 10.0.0.0/16 |
| Inbound | ACCEPT 200 | 192.168.0.0/16 | 10.0.0.0/16 |
| Outbound | ACCEPT 100 | 10.0.0.0/16 | 172.16.0.0/12 |
| Outbound | ACCEPT 200 | 10.0.0.0/16 | 192.168.0.0/16 |
| Both | REJECT 32767 | fallback | fallback |

- `MIRROR_VNI=12345`：统一标识
- `packet-length=128`：只镜像头部，降低 ~90% 带宽

---

## 七、Probe 内核调优

| 参数 | 目的 |
|------|------|
| `net.core.rmem_max` / `rmem_default` 增大 | 扩大 UDP 接收缓冲区防丢包 |
| RPS (Receive Packet Steering) 启用 | 多核分发网卡中断 |
| GRO (Generic Receive Offload) 关闭 | 避免合并影响逐包解析 |

实例 c6gn.2xlarge (ARM, 40Gbps NIC) 适配高吞吐场景。

---

## 八、ENI 生命周期管理 (`10-eni-lifecycle.sh`)

Cron Job 每 2 分钟执行：
1. 枚举当前 Appliance ENI (by PROJECT_TAG)
2. 枚举当前 Mirror Session (by PROJECT_TAG)
3. Diff: 新增 ENI → 建 session；下线 ENI → 删 session

解决 Appliance 扩缩容时 Mirror Session 不同步的问题。

---

## 九、测试策略

### 单元测试
| 文件 | 覆盖 |
|------|------|
| `tests/test_fast_parse.py` | C/Python 解析器等价性、截断包、非 IPv4、无效 IHL |
| `tests/test_multiproc_probe.py` | Coordinator 队列合并、采样放大、确定性、安全停止 |

### 集成测试
| 文件 | 内容 |
|------|------|
| `tests/integration_test.py` | 启动 probe → 发 50 flows × 200 pkts → 验证捕获率 ≥50% |

### 压力测试
| 文件 | 内容 |
|------|------|
| `tests/stress_test.py` | 4 线程 15s 持续发包，测量 pps 吞吐 |
| `tests/vxlan_flood.c` | C 线速 VXLAN 洪泛工具 |

### E2E 基础设施测试 (`tests/run-all.sh`)
VPN 模拟环境 → 流量发生 → 验证 Probe 检测

---

## 十、配置参数

### 基础设施 (`config/dx-monitor.conf`)

| 参数 | 说明 |
|------|------|
| `AWS_REGION` | 部署区域 |
| `VPC_ID` / `VPC_CIDR` | 目标 VPC |
| `VGW_ID` | VPN Gateway |
| `ONPREM_CIDRS` | On-prem 网段（Mirror Filter） |
| `WORKLOAD_SUBNETS` | Appliance/Probe/GWLB/NLB 子网 |
| `GWLBE_SUBNETS` | GWLB Endpoint 子网 |
| `BUSINESS_SUBNET_CIDRS` | 业务子网 CIDR |
| `APPLIANCE_INSTANCE_TYPE` | 默认 c6g.large |
| `PROBE_INSTANCE_TYPE` | 默认 c6gn.2xlarge |
| `MIRROR_VNI` | 默认 12345 |
| `PROJECT_TAG` | 默认 dx-monitoring |

### Probe 运行时（环境变量）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PROBE_WORKERS` | 0 (自动) | Worker 进程数 |
| `PROBE_SAMPLE_RATE` | 1.0 | 采样率 |
| `SNS_TOPIC_ARN` | 空 | SNS 告警主题 |
| `ALERT_THRESHOLD_BPS` | 1000000000 | 带宽阈值 |
| `ALERT_THRESHOLD_PPS` | 500000 | 包速率阈值 |
| `SLACK_WEBHOOK_URL` | 空 | Slack 地址 |

---

## 十一、运行时状态 (`env-vars.sh`)

部署脚本自动生成，记录所有 AWS 资源 ID。
每个脚本通过 `save_var()` 写入、`check_var_exists()` 检查幂等。

---

## 十二、容量规划

| 维度 | 建议 |
|------|------|
| Probe | 每 AZ ≥ 1 台 c6gn.2xlarge (40Gbps) |
| Appliance | 每 AZ ≥ 1 台 c6g.large |
| packet-length | 128B（降低 ~90% 镜像带宽） |
| Filter | 仅 on-prem ↔ VPC |
| 采样率 | 高流量环境 0.1-0.5 |
| Worker 数 | 默认 = CPU 核数 |

---

## 十三、实现细节

### 13.1 Probe 部署实现 (`08-probe-deploy.sh`)

部署流程通过 SSH 连接 Probe 私有 IP：

1. **SCP** 整个 `probe/` 目录到 `ec2-user@<ip>:~/probe/`
2. **pip install** `requirements.txt` (boto3, requests)
3. 创建 **systemd service** `/etc/systemd/system/dx-probe.service`
4. `systemctl enable && start dx-probe`
5. 验证 `is-active` 状态

systemd 服务配置：
```ini
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /home/ec2-user/probe/multiproc_probe.py
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=PROBE_WORKERS=0
Environment=PROBE_SAMPLE_RATE=1.0
```

以 root 运行是因为需要 bind UDP/4789 特权端口和设置大 socket buffer。

### 13.2 Probe 实例初始化 (`04-probe-instances.sh`)

通过 EC2 UserData 在实例启动时执行：

```bash
# 安装依赖
yum install -y python3 python3-pip tcpdump gcc

# NIC ring buffer 调优
ethtool -G eth0 rx 4096 tx 4096
ethtool -C eth0 rx-usecs 0 tx-usecs 0   # 禁用中断合并（低延迟）

# 内核 socket buffer
echo 268435456 > /proc/sys/net/core/rmem_max      # 256MB
echo 134217728 > /proc/sys/net/core/rmem_default   # 128MB

# 内核 RX 队列深度
echo 300000 > /proc/sys/net/core/netdev_max_backlog

# GRO 开启（聚合提升吞吐）
ethtool -K eth0 gro on

# RPS 多核分发
CPUS=$(nproc)
RPS_MASK=$(printf '%x' $(( (1 << CPUS) - 1 )))
for f in /sys/class/net/eth0/queues/rx-*/rps_cpus; do
    echo "$RPS_MASK" > "$f"
done

# 编译 C 解析器
gcc -O2 -shared -fPIC -o fast_parse.so fast_parse.c
```

### 13.3 C VXLAN 解析器实现 (`fast_parse.c`)

核心数据结构和 API：

```c
struct flow_result {
    uint32_t src_ip, dst_ip;   // 网络字节序 IP
    uint8_t  protocol;         // IP 协议号 (6=TCP, 17=UDP)
    uint16_t src_port, dst_port;
    uint16_t pkt_len;          // IP total length
};

// 返回 0 成功，-1 失败（非 IPv4、截断等）
int parse_vxlan_packet(const uint8_t *data, int len, struct flow_result *r);

// 将 host-order uint32 IP 转为点分十进制字符串
void ip_to_str(uint32_t ip, char *buf, int buf_len);
```

设计特点：
- 纯 inline 函数，零动态内存分配
- 单次顺序扫描：`VXLAN(8B) → Ethernet(14B) → IP(20B+) → L4 Ports`
- 最少条件分支：先验证最小长度，再逐层解析
- Python 通过 `ctypes.CDLL` 加载 `.so`，失败时自动 fallback

### 13.4 多进程 Worker 实现

每个 Worker 独立执行：

```python
# 1. 创建 SO_REUSEPORT socket
sock = socket.socket(AF_INET, SOCK_DGRAM)
sock.setsockopt(SOL_SOCKET, SO_REUSEPORT, 1)
sock.setsockopt(SOL_SOCKET, SO_RCVBUF, 128 * 1024 * 1024)  # 128MB
sock.bind(("0.0.0.0", 4789))

# 2. 收包循环
while not stop_event.is_set():
    data, _ = sock.recvfrom(65535)
    result = parse(data)         # C 或 Python 解析
    if sampling:                 # hash 确定性采样
        if hash(key) % 10000 >= threshold:
            continue
    flows[key] += (pkts, bytes)

    # 3. 每 5s flush 到 Coordinator Queue
    if now - last_flush >= 5.0:
        result_queue.put(dict(flows))
        flows.clear()
```

### 13.5 Coordinator 合并与报告

```python
# 每 5s 从所有 Worker Queue 收集
merged = defaultdict(lambda: [0, 0])
for q in queues:
    while snapshot := q.get_nowait():
        for key, (pkts, bytes) in snapshot.items():
            merged[key][0] += pkts
            merged[key][1] += bytes

# 采样放大：如果 sample_rate=0.5，计数 ×2
if inv_rate != 1.0:
    for v in merged.values():
        v[0] = int(v[0] * inv_rate)
        v[1] = int(v[1] * inv_rate)

# 排序输出 Top-10 + IP 富化 + 告警检查
```

### 13.6 IP 富化实现 (`enricher.py`)

```python
class IPEnricher:
    # 后台 daemon 线程，每 60s 刷新
    def _refresh(self):
        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate(Filters=[vpc-id]):
            for instance in page:
                for nic in instance.NetworkInterfaces:
                    cache[ip] = {instance_id, name, asg, owner}

    # 线程安全查询
    def enrich(self, ip) -> dict:
        with self._lock:
            return self._cache.get(ip, {})
```

### 13.7 告警实现 (`alerter.py`)

触发逻辑：
```
if (bps > threshold_bps OR pps > threshold_pps)
   AND (now - last_alert > cooldown_300s):
    → 格式化告警消息 (Top 5 src/dst/flows + 实例名)
    → SNS publish (subject 限 100 字符)
    → Slack webhook (markdown code block)
```

人类可读格式转换：`bytes_to_human()`, `bps_to_human()`, `pps_to_human()`
- 自动选择单位：B/KB/MB/GB/TB, bps/Kbps/Mbps/Gbps

### 13.8 IAM 权限实现

Probe 实例通过 Instance Profile 获取权限：

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "<SNS_TOPIC_ARN>"
    }
  ]
}
```

创建流程：`create-role` → `put-role-policy` → `create-instance-profile` → `add-role-to-instance-profile` → 等 10s IAM 传播

### 13.9 幂等机制实现

脚本通过 `env-vars.sh` 实现幂等：

```bash
# 检查资源是否已创建
if check_var_exists PROBE_INSTANCE_ID_0; then
    log_info "Already exists, skipping"
    return
fi

# 创建资源
INSTANCE_ID=$(aws ec2 run-instances ...)

# 持久化
save_var PROBE_INSTANCE_ID_0 "$INSTANCE_ID"
load_env  # 立即加载到当前 shell
```

`save_var` 写入 `env-vars.sh`（grep -v 旧值 + 追加新值），`check_var_exists` 检查变量是否已定义。

---

## 十四、生产踩坑记录

| 问题 | 根因 | 修复 |
|------|------|------|
| Mirror 零流量 | `--protocol 0` = HOPOPT，不是全部协议 | 省略 `--protocol` |
| NLB 健康检查失败 | Probe SG 未放行 VPC 内 TCP/22 | 添加 VPC_CIDR |
| 脚本中断 | `((var++))` 在 `set -e` 下返回 1 | `var=$((var+1))` |
| 变量未定义 | `save_var` 后未 `load_env` | 操作后立即 `load_env` |
| TG 打标签失败 | `ec2 create-tags` 不支持 ELBv2 ARN | 创建时用 `--tags` |
| Probe API 失败 | 缺少 IAM Role | 创建 Instance Profile |
| SSM 不可用 | 私有子网无出网 | 添加 NAT Gateway |
