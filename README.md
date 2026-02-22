# DX/VPN Traffic Mirroring 监控系统

通过 AWS Traffic Mirroring 实时监控经 VGW 进入 VPC 的 DX/VPN 流量，秒级识别 Top Talker，支持阈值告警。

## 架构

```
on-prem ──VPN/DX──> VGW ──> 业务子网
                                │ Traffic Mirror (VXLAN UDP 4789)
                                v
                        NLB (internal, cross-zone) ──> Probe 实例
                                                   (解封装 → 5s 聚合 → Top-N → 告警)
```

## 快速开始

```bash
# 1. 编辑配置
vi config/dx-monitor.conf

# 2. 顺序执行
bash scripts/00-init-config.sh
bash scripts/01-security-groups.sh
bash scripts/02-gwlb-appliance.sh   # 可与 04 并行
bash scripts/03-vgw-ingress-routing.sh
bash scripts/04-probe-instances.sh   # 可与 02 并行
bash scripts/05-nlb-mirror-target.sh
bash scripts/06-mirror-filter.sh
bash scripts/07-mirror-sessions.sh
bash scripts/08-probe-deploy.sh
bash scripts/09-verify.sh

# 3. 清理
bash scripts/99-cleanup.sh
```

## 目录结构

```
config/dx-monitor.conf       # VPC/VGW/子网/告警参数
scripts/lib/common.sh        # 共享函数库
scripts/00-10,99-cleanup.sh  # 部署+运维脚本
probe/vxlan_probe.py         # VXLAN 解封装 + 5s 聚合
probe/enricher.py            # IP → 实例归属映射
probe/alerter.py             # 阈值告警 (SNS + Slack)
tests/                       # VPN 模拟 E2E 测试
```

## 子网规划

| 子网 | 用途 |
|------|------|
| WORKLOAD_SUBNETS | Appliance + Probe + GWLB + NLB 共用 |
| GWLBE_SUBNETS | Gateway LB Endpoint (VGW 入口) |
| Business Subnets | 业务主机 |

## 安全组

| SG | 入站 |
|----|------|
| dx-appliance-sg | UDP 6081 (Geneve) from VPC; SSH from ADMIN |
| dx-probe-sg | UDP 4789 (VXLAN) from VPC; TCP 22 from VPC+ADMIN |

Probe SG 必须允许 TCP/22 from VPC_CIDR（NLB 健康检查）。

## E2E 测试

用 Site-to-Site VPN 模拟 DX，5 个流量发生器差异化速率：

```bash
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
