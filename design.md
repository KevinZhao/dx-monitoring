# DX/VPN Traffic Mirroring 监控系统 — 设计文档

## 一、设计目标

- **秒级实时**：5s 聚合窗口识别 Top Talker
- **不依赖托管监控**：不靠 VPC Flow Logs / CloudWatch 做定位
- **可执行告警**：消息直接给出 Top 源 IP/实例 + Top 目的端口 + Top 5-tuple
- **水平扩展**：每 AZ 独立 Probe 实例，多进程 SO_REUSEPORT 并行处理
- **高性能**：C 解析器 10x 加速，确定性采样支撑高流量场景

---

## 二、总体架构

系统支持两种部署模式，通过 `DEPLOY_MODE` 配置切换：

### B1 模式：GWLB 集中镜像 (`DEPLOY_MODE="gwlb"`)

```
On-Prem ─── DX/VPN ──→ VGW
                          │ Ingress Route Table (edge association)
                          v
                   GWLBE → GWLB → Appliance (透传转发)
                                        │
                                  Mirror Session (ENI)
                                  128B 截断, VNI=12345
                                        │
                                   NLB (UDP 4789) → Probe × N
```

流量路径：VGW → GWLBE → GWLB → Appliance（Geneve）→ 业务子网。Appliance ENI 作为 Mirror 源。

### B2 模式：业务 ENI 直接镜像 (`DEPLOY_MODE="direct"`, 推荐)

```
On-Prem ─── DX/VPN ──→ VGW ──→ 正常 VPC 路由（不经过 GWLB）
                                        │
                    ┌───────────────────┼───────────────────┐
                    v                   v                   v
              业务 EC2-0          业务 EC2-1    ...   业务 EC2-N
              ENI-0 ──Mirror──→                           ──Mirror──→
                    └───────────────────┬───────────────────┘
                                        v
                                   Probe ENI (直接, 无 NLB)
```

流量路径：VGW → 业务子网（正常路径）。每个业务 ENI 直接镜像到 Probe ENI。Lambda + EventBridge 自动管理 Mirror Session 生命周期。单 Probe 模式无需 NLB 负载均衡，方案为**纯固定成本**。

### 128B 包截断流水线

截断发生在 **ENI hypervisor 层**，在 VXLAN 封装之前，不消耗实例 CPU/内存：

```
① 原始包到达/离开业务 ENI (1000B)
   [Ethernet 14B][IP hdr: total_length=980][TCP hdr][Payload]

② Hypervisor 匹配 Mirror Filter → ACCEPT

③ Hypervisor 截断到 128B (packet-length=128)
   [Ethernet 14B][IP hdr: total_length=980 ← 保留原值][TCP ports][截断...]
                                   ↑ Probe 从这里读真实包大小

④ Hypervisor 加 VXLAN 封装发往 Mirror Target
   [外层 IP 20B][外层 UDP 8B][VXLAN 8B][截断的原始包 128B] = 164B

⑤ Probe ENI 收到 164B（直接接收，无 NLB 中转）

⑥ Probe 剥 VXLAN → 从 IP header 读 total_length=980 → 统计真实字节数
```

截断不影响统计准确性：`pps` 准确（1 原始包 = 1 镜像包），`bytes` 准确（从 IP total_length 读取原始值，不是截断后的长度）。

### 方案对比与选择

| | B1 (GWLB) | B2 (Direct, 推荐) |
|---|----------|-------------------|
| 流量路径 | 改变（VGW → GWLBE → Appliance） | **不改变**（正常 VPC 路由） |
| 故障影响 | Appliance 故障 → **业务断流** | Probe 故障 → **只丢监控** |
| Mirror Session 数 | 2-3 个（Appliance ENI） | N 个（业务 ENI 数量） |
| Session 管理 | 手动/简单 | Lambda 自动化 |
| 成本 (20% avg) | ~$15,800/月 (GWLB 按 GB 计费) | **~$4,900/月** (session 按时计费) |
| 实例类型限制 | 无（Appliance 可控） | 业务实例需 Nitro (5 代+) |
| 适用场景 | 少量业务实例、非 Nitro 混合 | **100+ Nitro 实例（主流场景）** |

---

## 三、部署脚本流水线

脚本根据 `DEPLOY_MODE` 自动跳过不需要的步骤：

```
                          DEPLOY_MODE
                         /           \
                      gwlb          direct
                        │              │
00-init-config ─────────┼──────────────┤
01-security-groups ─────┼──────────────┤  (direct: 跳过 appliance-sg)
                        │              │
02-gwlb-appliance ──────┤         [skip]
03-vgw-ingress ─────────┤         [skip]
                        │              │
04-probe-instances ─────┼──────────────┤
05-nlb-mirror-target ───┼──────────────┤
06-mirror-filter ───────┼──────────────┤
                        │              │
07-mirror-sessions ─────┤         [skip]
                        │              │
08-probe-deploy ────────┼──────────────┤
09-verify ──────────────┼──────────────┤  (按模式验证不同组件)
                        │              │
                   [skip]──────────────┤  11-business-mirror-sync
                   [skip]──────────────┤  12-deploy-mirror-lambda
                        │              │
10-eni-lifecycle ───────┤         [skip]
99-cleanup ─────────────┼──────────────┤  (按模式清理对应资源)
```

### 脚本清单

| 脚本 | 功能 | B1 | B2 | 幂等机制 |
|------|------|:--:|:--:|----------|
| `00-init-config.sh` | 验证配置、解析 AMI、生成 `env-vars.sh` | ✅ | ✅ | Name tag 查重 |
| `01-security-groups.sh` | Appliance SG + Probe SG | ✅ | ✅(仅 probe-sg) | `ensure_sg_ingress/egress` |
| `02-gwlb-appliance.sh` | Appliance + GWLB + Endpoint Service + GWLBE | ✅ | ⏭️ | check_var_exists |
| `03-vgw-ingress-routing.sh` | VGW Ingress Route Table + Edge Association | ✅ | ⏭️ | check_var_exists |
| `04-probe-instances.sh` | Probe 实例 + IAM Role/Profile + 内核调优 | ✅ | ✅ | check_var_exists |
| `05-nlb-mirror-target.sh` | gwlb: NLB + Mirror Target; direct: Probe ENI Mirror Target | ✅ | ✅ | check_var_exists |
| `06-mirror-filter.sh` | ACCEPT on-prem ↔ VPC, REJECT fallback | ✅ | ✅ | check_var_exists |
| `07-mirror-sessions.sh` | Appliance ENI Mirror Session | ✅ | ⏭️ | ENI 枚举去重 |
| `08-probe-deploy.sh` | 部署 probe 代码 + systemd 服务 | ✅ | ✅ | systemctl restart |
| `09-verify.sh` | 5 阶段验证（按模式检查不同组件） | ✅ | ✅ | 只读检查 |
| `10-eni-lifecycle.sh` | Cron 同步 Appliance Mirror Session | ✅ | ⏭️ | 增量同步 |
| `11-business-mirror-sync.sh` | Cron 同步业务 ENI Mirror Session | ⏭️ | ✅ | 全量 diff |
| `12-deploy-mirror-lambda.sh` | EventBridge + Lambda 实时同步 | ⏭️ | ✅ | create-or-update |
| `99-cleanup.sh` | 反序删除全部资源（含 Lambda/EventBridge） | ✅ | ✅ | `--force` 确认 |

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

Probe SG 放行 TCP/22 from VPC_CIDR 用于 NLB 健康检查（仅 gwlb 模式）。

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

实例 c8gn.4xlarge (ARM, 50Gbps NIC) 适配高吞吐场景。

---

## 八、Mirror Session 生命周期管理

### B1 模式：`10-eni-lifecycle.sh`（Cron）

Cron Job 每 2 分钟执行：
1. 枚举当前 Appliance ENI (by PROJECT_TAG)
2. 枚举当前 Mirror Session (by PROJECT_TAG)
3. Diff: 新增 ENI → 建 session；下线 ENI → 删 session

解决 Appliance 扩缩容时 Mirror Session 不同步的问题。

### B2 模式：双重同步机制

**实时层 — EventBridge + Lambda** (`lambda/mirror_lifecycle.py`):
```
EC2 state=running  → Lambda 检查是否在 BUSINESS_SUBNET → 创建 Mirror Session
EC2 state=terminated → Lambda 按 SourceInstance tag 查找 → 删除 Mirror Session
```
秒级响应，每次只处理 1 台实例变更。

**兜底层 — Cron** (`11-business-mirror-sync.sh`):
```
每 2 分钟全量 diff:
  期望状态 = BUSINESS_SUBNET_CIDRS 中所有 running 实例的主 ENI
  实际状态 = Mirror Target 关联的所有 session
  创建缺失、删除过期
```
处理 Lambda 遗漏（如 EventBridge 故障）、首次全量部署。两套机制幂等，可同时运行互不冲突。

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
| `DEPLOY_MODE` | `"gwlb"` (B1) 或 `"direct"` (B2, 推荐) |
| `AWS_REGION` | 部署区域 |
| `VPC_ID` / `VPC_CIDR` | 目标 VPC |
| `VGW_ID` | VPN Gateway |
| `ONPREM_CIDRS` | On-prem 网段（Mirror Filter） |
| `WORKLOAD_SUBNETS` | Appliance/Probe/GWLB/NLB 子网 |
| `GWLBE_SUBNETS` | GWLB Endpoint 子网 |
| `BUSINESS_SUBNET_CIDRS` | 业务子网 CIDR |
| `APPLIANCE_INSTANCE_TYPE` | c8gn.4xlarge（B1 模式，需网络优化实例） |
| `APPLIANCE_COUNT` | 2（每 AZ Appliance 台数，仅 B1） |
| `PROBE_INSTANCE_TYPE` | c8gn.8xlarge（32 vCPU, 100Gbps, 单台覆盖 40Gbps） |
| `PROBE_COUNT` | 1（单台看到全部流量，告警无需聚合） |
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

### B2 全量模式 (direct, SAMPLE_RATE=1.0)

| 组件 | 规格 | 数量 | 说明 |
|------|------|------|------|
| Probe | c8gn.8xlarge (100Gbps, 32 vCPU) | **1 台** | 32 workers ~5.36Mpps > 5Mpps@40Gbps，单台看到全部流量 |
| Mirror Session | 每业务 ENI 1 个 | N (按实例数) | packet-length=128, VNI=12345 |
| Lambda | mirror_lifecycle.py | 1 | 实时创建/删除 Mirror Session |
| C 流表 | 500K flows, 1M hash slots | — | 48% 负载因子 |
| Worker 数 | 默认 = CPU 核数 | — | 32 workers/实例 |

单 Probe 优势：**告警天然准确**，一台看到 100% 的 DX 流量，无需跨实例聚合。
费用与 2×c8gn.4xlarge 完全相同（$1,576/月）。Mirror Target 直接指向 Probe ENI，无需 NLB，方案为纯固定成本。

### B2 采样模式 (direct, SAMPLE_RATE=0.5, 推荐)

| 组件 | 规格 | 数量 | 说明 |
|------|------|------|------|
| Probe | c8gn.4xlarge (50Gbps, 16 vCPU) | **1 台** | 16 workers ~2.68Mpps，采样后实际处理 ~2.5Mpps |
| Mirror Session | 每业务 ENI 1 个 | N (按实例数) | packet-length=128, VNI=12345 |
| Lambda | mirror_lifecycle.py | 1 | 实时创建/删除 Mirror Session |
| Worker 数 | 默认 = CPU 核数 | — | 16 workers/实例 |

采样使用 hash 确定性机制：`hash(5-tuple) % 10000 < rate × 10000`，同一 flow 要么全采要么全跳，采集结果乘 `1/rate` 放大。

#### 采样精度分析

| 指标 | 精度 | 说明 |
|------|------|------|
| 聚合告警 (总 bps/pps > 阈值) | ±3% (1000+ flows) | 大数定律，active flow 越多越准 |
| Top Source/Dest IP | **可靠** | 数据同步 IP 通常有 10+ 连接，全部漏掉概率 0.5^10 ≈ 0.1% |
| Top 5-tuple (单条连接) | **50% 漏检** | 每条连接只有一次 hash 机会，无统计优势 |

适用场景：需要快速定位"哪个 IP 在吃带宽"（如数据同步打满链路），不需要精确到单条连接级别。

### B1 (gwlb) 40Gbps 配置

| 组件 | 规格 | 数量 | 说明 |
|------|------|------|------|
| Appliance | c8gn.4xlarge (50Gbps 持续) | 每 AZ 2 台 | 每台 ~44Gbps (含 2.18x 双向+镜像因子) |
| Probe | c8gn.4xlarge | 每 AZ 2 台 | 同上 |
| GWLB + GWLBE | — | 各 1 | 集中拦截 DX 流量 |

Appliance 网络带宽计算（B1）：
```
单 Appliance 承载 X Gbps:
  入向 (Geneve): ~1.05X  +  出向 (转发): ~X  +  镜像: ~0.13X  =  ~2.18X
40Gbps / 2 台 = 每台 ~20Gbps → 2.18 × 20 = ~43.6Gbps < 50Gbps
```

### 成本对比 (eu-central-1, 100 业务实例)

| 组件 | B1 (gwlb) | B2 全量 | B2 采样 (推荐) |
|------|----------|---------|---------------|
| Probe | $1,576 (2× c8gn.4xlarge) | $1,576 (1× c8gn.8xlarge) | **$788** (1× c8gn.4xlarge) |
| Appliance 2× c8gn.4xlarge | $1,576 | — | — |
| GWLB 固定 + GLCU (20% util) | $11,048 | — | — |
| NLB 固定 + NLCU (20% util) | $2,069 | — | — |
| Mirror Session | $26 (2 个) | $1,314 (100 个) | $1,314 (100 个) |
| Lambda + EventBridge | — | ~$1 | ~$1 |
| **月总计** | **~$16,300** | **~$2,891** | **~$2,103** |
| **Top IP 精度** | 精确 | 精确 | ±18% (10+ 连接/IP) |
| **Top 5-tuple 精度** | 精确 | 精确 | 50% 漏检 |
| **聚合告警精度** | 精确 | 精确 | ±3% (1000+ flows) |

### 镜像带宽计算

```
40Gbps DX (avg 1000B/pkt):
  pps = 40Gbps / (1000B × 8) = 5M pps
  镜像 (128B 截断): 5M × 128B × 8 = 5.12 Gbps  (原始的 ~13%)
  VXLAN 封装后:     5M × 164B × 8 = 6.56 Gbps   (Probe ENI 实际处理量)
```

每个业务 ENI 的镜像开销：如果平均分到 100 台，每台 400Mbps DX 流量 → 镜像仅 ~52Mbps（13%），对业务几乎无感。

### 丢包监控

系统在三个层面检测丢包：
- **内核 socket**: 读取 `/proc/net/udp` drops 列，Coordinator 每 5s 检查
- **C 流表溢出**: `cap_get_dropped_flows()` 计数器，Worker 每秒报告
- **Worker Queue**: 超时 0.1s 后 drop 并记录计数

### 告警异步化

SNS/Slack 发送已移至后台线程，避免在高流量告警触发时阻塞 Coordinator 收包。

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
| SG 规则丢失 | `create_sg_if_not_exists` 的 `log_info` 输出到 stdout，被 `$()` 捕获污染 SG ID，导致 authorize 调用 ID 错误后被 `\|\| log_warn` 静默吞掉 | log 输出加 `>&2`；新增 `ensure_sg_ingress/egress` helper 区分 Duplicate 和真实错误 |
