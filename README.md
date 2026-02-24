# DX/VPN Traffic Mirroring 监控系统

通过 AWS Traffic Mirroring 实时监控经 VGW 进入 VPC 的 DX/VPN 流量，秒级识别 Top Talker，支持阈值告警。

## 系统架构图

系统支持两种部署模式，通过 `DEPLOY_MODE` 配置切换：

### B2 模式：业务 ENI 直接镜像 (`DEPLOY_MODE="direct"`, 推荐)

```
┌──────────────────────────────────────────────────────────────────┐
│                       AWS VPC (10.0.0.0/16)                      │
│                                                                  │
│  On-Prem ──VPN/DX──> VGW ──> 正常 VPC 路由                       │
│  (172.16/12)                     │                               │
│  (192.168/16)    ┌───────────────┼───────────────┐               │
│                  v               v               v               │
│            业务 EC2-0      业务 EC2-1  ...  业务 EC2-N            │
│            ENI ──Mirror──→     ──Mirror──→  ──Mirror──→          │
│                  └───────────────┬───────────────┘               │
│                                  v                               │
│  WORKLOAD        ┌───────────────────────┐                       │
│  SUBNETS         │ Probe (c8gn.8xlarge)  │  ← Mirror Target     │
│                  │ 32 workers, 5.8M pps  │    (直接指向 Probe ENI)│
│                  └───────────┬───────────┘                       │
│                              │                                   │
│                              v                                   │
│                  ┌───────────────────────┐                       │
│                  │   Alerter (SNS+Slack) │                       │
│                  │   1.5s 告警 / 5s 报告  │                       │
│                  └───────────────────────┘                       │
│                                                                  │
│  Lambda + EventBridge 自动管理 Mirror Session 生命周期            │
└──────────────────────────────────────────────────────────────────┘
```

### B1 模式：GWLB 集中镜像 (`DEPLOY_MODE="gwlb"`)

```
┌──────────────────────────────────────────────────────────────────┐
│                       AWS VPC (10.0.0.0/16)                      │
│                                                                  │
│  On-Prem ──VPN/DX──> VGW                                        │
│  (172.16/12)          │ Ingress Route Table                      │
│  (192.168/16)         v                                          │
│              GWLBE (每AZ) → GWLB → Appliance ×N (透传转发)       │
│                                        │                         │
│                                  Mirror Session (ENI)            │
│                                        │                         │
│                                   NLB (UDP 4789) → Probe ×N     │
│                                        │                         │
│                                   Alerter (SNS+Slack)            │
└──────────────────────────────────────────────────────────────────┘
```

## Probe 内部架构

```
                          VXLAN UDP/4789 流量
                                │
                   Kernel SO_REUSEPORT 负载均衡
                ┌───────────────┼───────────────┐
                v               v               v
          ┌──────────┐   ┌──────────┐    ┌──────────┐
          │ Worker 0 │   │ Worker 1 │    │ Worker N │
          │          │   │          │    │          │
          │ C recvmmsg   │ C recvmmsg    │ C recvmmsg  fast_recv.so
          │ C Parser │   │ C Parser │    │ C Parser │  inline VXLAN parse
          │  Python) │   │  Python) │    │  Python) │
          │          │   │          │    │          │
          │ Flow     │   │ Flow     │    │ Flow     │  独立流表
          │ Aggregator   │ Aggregator   │ Aggregator  hash 采样
          └─────┬────┘   └─────┬────┘    └─────┬────┘
                │              │               │
                └──────┬───────┘               │
                       │  multiprocessing.Queue │
                ┌──────v───────────────────────v──┐
                │          Coordinator            │
                │  每 5s 合并所有 Worker 流数据     │
                │  按采样率放大 → Top-N 排序       │
                └──────────────┬──────────────────┘
                               │
                ┌──────────────v──────────────┐
                │          Enricher           │
                │  IP → {instance, name, ASG} │
                │  60s 刷新缓存               │
                └──────────────┬──────────────┘
                               │
                ┌──────────────v──────────────┐
                │          Alerter            │
                │  BPS/PPS 阈值检测           │
                │  300s 冷却 → SNS + Slack    │
                └─────────────────────────────┘
```

## 快速开始

```bash
# 1. 编辑配置（默认 DEPLOY_MODE="direct"）
vi config/dx-monitor.conf

# 2. B2 (direct) 模式部署
bash scripts/00-init-config.sh
bash scripts/01-security-groups.sh
bash scripts/04-probe-instances.sh
bash scripts/05-nlb-mirror-target.sh   # direct: Probe ENI target; gwlb: NLB target
bash scripts/06-mirror-filter.sh
bash scripts/08-probe-deploy.sh
bash scripts/11-business-mirror-sync.sh  # 同步业务 ENI mirror session
bash scripts/12-deploy-mirror-lambda.sh  # EventBridge + Lambda 实时同步
bash scripts/09-verify.sh

# 2b. B1 (gwlb) 模式额外步骤
bash scripts/02-gwlb-appliance.sh
bash scripts/03-vgw-ingress-routing.sh
bash scripts/07-mirror-sessions.sh
bash scripts/10-eni-lifecycle.sh

# 3. 清理
bash scripts/99-cleanup.sh
```

## 目录结构

```
config/dx-monitor.conf         # VPC/VGW/子网/告警参数
scripts/lib/common.sh          # 共享函数库 (load_config, save_var, wait_until)
scripts/00-10,99-cleanup.sh    # 部署+运维脚本 (12 个)
probe/multiproc_probe.py       # 多进程 VXLAN 探针 (主程序, SO_REUSEPORT)
probe/fast_recv.c              # C recvmmsg 批量收包 + hash table 聚合
probe/fast_parse.c             # C VXLAN 解析器 (10x 加速)
probe/enricher.py              # IP → 实例归属映射 (60s 缓存)
probe/alerter.py               # 阈值告警 (SNS + Slack, 300s 冷却)
probe/requirements.txt         # Python 依赖 (boto3, requests)
tests/test_fast_parse.py       # C/Python 解析器等价性测试
tests/test_multiproc_probe.py  # Coordinator/采样逻辑测试
tests/integration_test.py      # 端到端集成测试 (50 flows × 200 pkts)
tests/stress_test.py           # 压力测试 (4 线程, 15s 持续)
tests/vxlan_flood.c            # C 线速 VXLAN 洪泛工具
tests/00-04,99-*.sh            # E2E 基础设施测试 (VPN 模拟)
tests/run-all.sh               # 测试编排
```

## 子网规划

| 子网 | 用途 |
|------|------|
| WORKLOAD_SUBNETS | Probe 子网（gwlb 模式含 Appliance + GWLB + NLB） |
| GWLBE_SUBNETS | Gateway LB Endpoint（仅 gwlb 模式） |
| Business Subnets | 业务主机 |

## 安全组

| SG | 入站 | 适用模式 |
|----|------|----------|
| dx-appliance-sg | UDP 6081 (Geneve) from VPC; SSH from ADMIN | 仅 gwlb |
| dx-probe-sg | UDP 4789 (VXLAN) from VPC; TCP 22 from VPC+ADMIN | 全部 |

Probe SG 放行 TCP/22 from VPC_CIDR（gwlb 模式用于 NLB 健康检查）。

## 测试

```bash
# 单元测试
python -m pytest tests/test_fast_parse.py tests/test_multiproc_probe.py -v

# 集成测试
python -m pytest tests/integration_test.py -v

# 压力测试
python tests/stress_test.py

# E2E 基础设施测试
bash tests/run-all.sh              # 一键测试
bash tests/run-all.sh --skip-cleanup  # 保留资源
```

## 部署踩坑记录

| 问题 | 根因 | 修复 |
|------|------|------|
| Mirror 零流量 | `--protocol 0` = HOPOPT，不是所有协议 | 省略 `--protocol` |
| NLB 健康检查失败 | Probe SG 未放行 VPC 内 TCP/22 | 添加 VPC_CIDR |
| 脚本中断 | `((var++))` 在 set -e 下返回 1 | `var=$((var+1))` |
| 变量未定义 | `save_var` 后未 `load_env` | 添加 `load_env` |
| TG 打标签失败 | ec2 create-tags 不支持 ELBv2 ARN | 创建时用 --tags |
| Probe API 失败 | 缺少 IAM Role | 创建 Instance Profile |
| SSM 不可用 | 私有子网无出网 | 添加 NAT Gateway |
