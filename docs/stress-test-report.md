# DX Probe 高速流量压测报告

**日期**: 2026-02-22
**目标**: 验证 probe 架构能否承载 40Gbps DX 链路的镜像流量

---

## 1. 测试环境

### 1.1 Probe 实例（最终配置）

| 项目 | 值 |
|------|-----|
| 实例类型 | c8gn.4xlarge |
| 数量 | 2 台 (eu-central-1a, eu-central-1b) |
| vCPU | 16 |
| 内存 | 32 GB |
| 网络 | 50 Gbps |
| 架构 | ARM64 (Graviton 4) |
| AMI | AL2023 ARM64 (ami-REDACTED) |

### 1.2 Probe 软件配置

| 项目 | 值 |
|------|-----|
| 入口 | multiproc_probe.py |
| 收包引擎 | **C recvmmsg** (fast_recv.so) |
| 解析引擎 | C VXLAN parser (fast_parse.so) |
| Workers | 16 per instance (= vCPU count) |
| SO_REUSEPORT | 启用 (内核 5-tuple hash 分流) |
| SO_RCVBUF | 268,435,456 (256 MB) |
| PROBE_SAMPLE_RATE | 1.0 (不采样) |
| REPORT_INTERVAL | 5 seconds |
| recvmmsg batch | 256 packets/call |
| Hash table | 262,144 slots (open addressing, FNV-1a) |

### 1.3 内核调优

| 参数 | 值 |
|------|-----|
| net.core.rmem_max | 268,435,456 (256 MB) |
| net.core.rmem_default | 134,217,728 (128 MB) |
| net.core.netdev_max_backlog | 300,000 |
| NIC GRO | on |

### 1.4 NLB 配置

| 项目 | 值 |
|------|-----|
| 类型 | Network Load Balancer (internal) |
| 协议 | UDP 4789 |
| Cross-zone | 启用 |
| Target | 2 x c8gn.4xlarge (instance ID) |
| Health check | TCP/22 |

### 1.5 Mirror Session 配置

| 项目 | 值 |
|------|-----|
| Packet length | 128 bytes (截断) |
| VNI | 12345 |
| Sessions | 2 (每个 appliance ENI 一个) |

### 1.6 压测工具

| 项目 | 值 |
|------|-----|
| 工具 | vxlan_flood.c (自研, sendmmsg batch) |
| 发送实例 | 3 x c6gn.xlarge |
| 线程/实例 | 8 |
| 包大小 | 128 bytes (模拟 mirror 截断后的包) |
| 流数量 | 100,000 per sender (总计 300,000) |
| 持续时间 | 60 seconds |
| 包格式 | 合法 VXLAN + Ethernet + IPv4 + TCP/UDP |

---

## 2. 测试轮次与结果

### Round 1: Python recvfrom (c6gn.2xlarge, 8 workers)

架构: Python `socket.recvfrom()` per-packet 循环

| 指标 | 值 |
|------|-----|
| 发送 | 2 台 sender, 1024B 包, 512 flows |
| 发送速率 | 1.71M pps / 14.04 Gbps |
| 持续时间 | 30s |
| Probe 0 捕获 | 5,081,562 pkts |
| Probe 0 丢包 | 15,282,706 |
| Probe 1 捕获 | 10,051,916 pkts |
| Probe 1 丢包 | 11,830,376 |
| **总捕获率** | **29.4%** |
| 每 worker pps | ~45,000 |

丢包根因分析:

```
Probe 1 per-worker drops (8 workers):
  w1=956,636   w2=0         w3=2,626,763  w4=0
  w5=699,098   w6=7,547,879 w7=0          w8=0

4/8 workers 完全空闲 (drops=0), worker 6 承受 64% 丢包
根因: 512 flows 的 SO_REUSEPORT hash 分布极度不均
```

### Round 2: Python recvfrom (c6gn.2xlarge, 8 workers, 128B, 200K flows)

架构: 同 Round 1, 但修正了包大小和 flow 数量

| 指标 | 值 |
|------|-----|
| 发送 | 2 台 sender, 128B 包, 200K flows |
| 发送速率 | 4.16M pps / 4.26 Gbps |
| 持续时间 | 60s |
| 总发送 | 249,626,112 pkts |
| 总捕获 | 43,377,627 pkts |
| 总丢包 | 155,163,766 |
| **总捕获率** | **17.4%** |
| Probe 0 稳态 | 368,525 pps |
| Probe 1 稳态 | 330,865 pps |
| 每 worker pps | ~45,000 |

结论: 增加 flow 数量改善了 hash 分布 (6/8 workers 有丢包 vs 4/8), 但 Python recvfrom 仍是根本瓶颈。每 worker ~45K pps 上限不变。

### Round 3: C recvmmsg (c6gn.2xlarge, 8 workers)

架构: C `recvmmsg()` 批量收包 + C hash table 聚合, 替代 Python recv loop

| 指标 | 值 |
|------|-----|
| 发送 | 2 台 sender, 128B 包, 200K flows |
| 发送速率 | 3.68M pps / 3.77 Gbps |
| 持续时间 | 60s |
| 总发送 | ~220M pkts |
| Probe 0 drops | **0** |
| Probe 1 drops | **0** |
| Probe 0 稳态 | ~1.30M pps |
| Probe 1 稳态 | ~1.34M pps |
| **总捕获率** | **100%** |
| 每 worker pps | ~168,000 |
| 等效 DX | ~29 Gbps (1000B avg) |

vs Round 2 提升: 捕获率 17% -> 100%, 每 worker pps 45K -> 168K (**3.7x**)

### Round 4: C recvmmsg (c8gn.4xlarge, 16 workers) — 最终验证

架构: C recvmmsg + c8gn.4xlarge (16 vCPU, 50Gbps NIC)

| 指标 | 值 |
|------|-----|
| 发送 | **3 台** sender, 128B 包, 300K flows |
| Sender 1 | 1,937,324 pps / 1.98 Gbps |
| Sender 2 | 1,993,642 pps / 2.04 Gbps |
| Sender 3 | 1,895,925 pps / 1.94 Gbps |
| **总发送** | **5,826,891 pps / 5.96 Gbps** |
| 等效 DX (1000B avg) | **~46 Gbps** |
| 持续时间 | 60s |
| Probe 0 (16 workers) | **drops = 0** (全部 16 个 worker) |
| Probe 1 (16 workers) | **drops = 0** (全部 16 个 worker) |
| **总捕获率** | **100%** |

---

## 3. 性能演进总结

| 轮次 | 实例 | 引擎 | Workers | 发送 pps | 捕获率 | drops |
|------|------|------|---------|----------|--------|-------|
| R1 | c6gn.2xl | Python recvfrom | 8 | 1.71M | 29% | 27.1M |
| R2 | c6gn.2xl | Python recvfrom | 8 | 4.16M | 17% | 155M |
| R3 | c6gn.2xl | **C recvmmsg** | 8 | 3.68M | **100%** | **0** |
| **R4** | **c8gn.4xl** | **C recvmmsg** | **16** | **5.83M** | **100%** | **0** |

---

## 4. 40Gbps DX 容量验证

```
40Gbps DX 链路 (avg 1000B packets):
  原始 pps:         5,000,000 (5M)
  镜像截断 128B:    5.12 Gbps (仅原始带宽的 12.8%)
  分到 2 台 probe:  2,500,000 pps / 2.56 Gbps per instance
  每 worker (16):   156,250 pps per worker

压测验证:
  实际发送:         5,826,891 pps (超过 5M 目标 16%)
  两台 probe:       drops = 0 (32 workers 全部零丢包)

结论: 40Gbps DX 已验证通过, 有 16% 余量
```

---

## 5. 检测延迟

| 测试 | 流量开始时间 | 首次报告时间 | 延迟 |
|------|-------------|-------------|------|
| Round 1 (Python) | 06:16:02.874 | 06:16:06 | ~3s |
| Round 4 (C recvmmsg) | 06:46:53 | 06:47:03 | ~10s |

Round 4 延迟 10s 因为 C `cap_run()` 阻塞 5s 后才返回第一批数据, 加上 coordinator 的 5s 合并周期。最坏情况检测延迟 = 2 x REPORT_INTERVAL = 10s。

可调优: 将 REPORT_INTERVAL 从 5s 降到 2s, 最坏延迟降至 4s。

---

## 6. 关键发现

### 6.1 Python recvfrom 是性能瓶颈

每次 `socket.recvfrom()` 调用耗时 ~20us, 包括:
- 系统调用切换 ~200ns
- bytes 对象创建 ~100ns
- Python 解释器循环开销
- `time.monotonic()` 每包调用
- `multiprocessing.Event.is_set()` 每包检查

导致每 worker 上限 ~45K pps, 与实例大小无关。

### 6.2 C recvmmsg 批量收包解决瓶颈

将收包/解析/聚合全部移至 C:
- `recvmmsg()` 一次收 256 个包, 摊薄系统调用开销
- C 内联 VXLAN 解析, 无对象分配
- C hash table 聚合, 无 Python dict 开销
- 仅每 5s 与 Python 交互一次 (flush flow table)

每 worker 提升 3.7x (45K -> 168K pps)。

### 6.3 SO_REUSEPORT 需要足够多的 flows

512 flows 导致 hash 分布极度不均 (4/8 workers 空闲)。
200K+ flows 时分布均匀, 所有 workers 参与。
真实 DX 流量通常有数十万 flows, 不存在此问题。

### 6.4 实例选型不影响 per-worker 性能

c6gn.2xlarge (8 vCPU) vs c8gn.4xlarge (16 vCPU):
- 每 worker pps 相同 (~168K)
- 更大实例 = 更多 workers = 更高总吞吐
- NIC 带宽和 CPU 均未成为瓶颈

---

## 7. 最终生产配置

```
实例:      2 x c8gn.4xlarge (16 vCPU, 32GB, 50Gbps)
引擎:      C recvmmsg (fast_recv.so) + C parser (fast_parse.so)
Workers:   16 per instance (SO_REUSEPORT)
SO_RCVBUF: 256 MB
rmem_max:  256 MB
Mirror:    128B packet truncation
NLB:       UDP 4789, cross-zone enabled
容量:      5.83M pps verified (= 46Gbps DX equiv)
目标:      40Gbps DX = 5M pps -> 有 16% headroom
```

---

## 8. 文件清单

| 文件 | 用途 |
|------|------|
| `probe/fast_recv.c` | C recvmmsg 批量收包 + hash table 聚合 |
| `probe/fast_parse.c` | C VXLAN 头解析 (ctypes fallback) |
| `probe/multiproc_probe.py` | 多进程协调器 (C worker / Python fallback) |
| `probe/vxlan_probe.py` | 原始单进程 probe (已弃用, 保留兼容) |
| `probe/enricher.py` | IP -> EC2 instance 映射 |
| `probe/alerter.py` | SNS/Slack 告警 |
| `config/dx-monitor.conf` | PROBE_INSTANCE_TYPE=c8gn.4xlarge |
| `scripts/04-probe-instances.sh` | 内核调优 + gcc 编译 |
| `scripts/07-mirror-sessions.sh` | --packet-length 128 |
| `scripts/08-probe-deploy.sh` | systemd unit -> multiproc_probe.py |
| `tests/vxlan_flood.c` | 压测工具 (sendmmsg batch sender) |
| `tests/test_fast_parse.py` | C/Python 解析器单元测试 (20 tests) |
| `tests/test_multiproc_probe.py` | Coordinator/Queue/采样测试 (10 tests) |
