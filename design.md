下面给你一套**统一覆盖两条链路（通过 TGW 的 DX、通过 VGW 的 DX/VPN）**的 Traffic Mirroring 设计方案 + 实施方案，目标是：
	•	尽量实时（秒级～十秒级发现/定位 top talker）
	•	尽量不依赖 AWS 托管监控（不靠 VPC Flow Logs/CloudWatch 来做定位）
	•	报警消息里直接给出：Top 源私网 IP/实例 + Top 目的端口/对端地址 + Top 5-tuple

关键前提：Traffic Mirroring 的镜像源是 VPC 里的 ENI，镜像流量会被 VXLAN（UDP 4789）封装发给镜像目标。 ￼
所以 TGW/VGW 这两条路，核心就是找到“必经 ENI/汇聚 ENI”，尽量少镜像、镜像得准。

⸻

一、总体架构（共用一套镜像目标与探针集群）

1) Mirror Target（共用）
	•	用一个 **内部 Network Load Balancer（UDP 4789）**做 mirror target
	•	NLB 后面挂多台“探针实例”（每 AZ 至少 1 台），便于横向扩容/容灾
	•	文档明确：Traffic Mirroring 可把镜像流量送到 NLB；并要求 target 侧允许 VXLAN UDP 4789。 ￼

探针实例职责（自建）
	•	解 VXLAN → 得到 inner packet（真实 src/dst/port/proto）
	•	做流量聚合（建议 5s/10s 滚动窗口）：top src_ip / top dst / top 5-tuple / top pps/bps
	•	写入自建存储（例如 ClickHouse/TSDB），并触发你自建告警（Prometheus/Alertmanager 或你们现有告警系统）

⸻

二、两条链路分别“镜像哪里”

A) DX 通过 TGW 的链路：只镜像 TGW VPC Attachment 的 ENI（强烈推荐）

原因：TGW 在你选择的 attachment 子网里会部署 ENI，用它们来承载该 AZ 的进出流量。 ￼
所以这些 ENI 就是天然汇聚点：镜像它们 = 基本覆盖“on-prem ↔ VPC”全部流量。

你需要做什么
	•	找出每个相关 VPC attachment 在各 AZ 的那几张 ENI
	•	给每张 ENI 建一个 mirror session（source=该 ENI，target=NLB，filter=onprem↔vpc）

一般不需要对 VPC 内所有实例 ENI 镜像，除非你链路中存在 NAT/代理改写导致归因困难（后面我会给兜底方案）。

⸻

B) DX 通过 VGW 的链路：两种策略（选其一）

B1（推荐，像 TGW 一样“少 ENI 汇聚”）：VGW Ingress Routing → GWLB Endpoint → 你可控的“汇聚 ENI”，再镜像这组 ENI

AWS 已支持在 VGW 的 ingress route table 里把 next-hop 指到 Gateway Load Balancer Endpoint（GWLBE），从而把入口流量导入你可控的 appliance 路径。 ￼

实现效果
	•	on-prem → VGW →（ingress routing）→ GWLBE/GWLB →（你的 appliance/探针/防火墙实例）→ 业务子网
	•	于是“入口汇聚 ENI”变成 appliance 实例 ENI（数量少、易管理）
	•	然后你只需要 mirror appliance ENI（跟 TGW attachment ENI 类似）

这条路线会改变流量路径（插入检查/转发点）。如果你接受做集中式入口治理/可观测，这是最省镜像 session 的。

B2（不改路径）：分散式镜像业务 ENI（成本高、运维重）
	•	直接对 VGW 相关业务子网内的关键实例 ENI 做 mirror session
	•	实例很多时 session 数会爆炸；且 ASG/EKS 节点扩缩容时你要自动跟进创建/删除 session

⸻

三、Mirror Filter 设计（强烈建议“只镜像你关心的那部分”）

无论 TGW 还是 VGW，都建议 filter 做到最小化镜像量：
	1.	只镜像 on-prem CIDR ↔ VPC CIDR
	2.	优先只镜像一个方向（例如先 outbound：VPC→on-prem，通常定位“谁在打出去”就够）
	3.	只放行关键端口（443/445/数据库端口/消息队列端口等）

这样你既能“更实时”，又能让探针不被打爆。

⸻

四、实施方案（控制台步骤 + 关键校验）

Phase 1：搭共用 Mirror Target（一次搭好，TGW/VGW 共用）

1）创建探针实例
	•	EC2 → Launch instance（每 AZ ≥ 1）
	•	安全组入站允许 UDP 4789（至少来自 VPC CIDR；后续可收紧到镜像源子网段）
	•	确保实例网卡/内核能力能接住流量（建议先做压测）

mirror target 必须允许 VXLAN（UDP 4789）。 ￼

2）创建内部 NLB（UDP 4789）
	•	EC2 → Load Balancers → Create → Network Load Balancer
	•	Listener：UDP / 4789
	•	Target Group：UDP / 4789，把探针实例注册进去
	•	建议启用 cross-zone（容灾/均衡更稳）
	•	这是官方支持的 target 模式。 ￼

3）创建 Mirror Target（指向 NLB）
	•	VPC → Traffic Mirroring → Mirror targets → Create
	•	Target type 选 Network Load Balancer，选上面的 NLB
	•	完成

⸻

Phase 2A：接入 TGW 路径（只镜像 TGW attachment ENI）

4A）定位 TGW attachment ENI
	•	EC2 → Network Interfaces
	•	过滤：VPC=目标 VPC；子网=你当初用于 attachment 的子网（每 AZ 一个）
	•	通常 Description/Owner 信息会体现是 TGW 使用的 ENI（不同环境展示略有差异）
	•	你也可以从 “TGW VPC attachment 必须指定每 AZ 一个子网作为进出入口”这个原则倒推：这些子网里的“系统管理 ENI”就是你要找的。 ￼

5A）创建 Mirror Filter（onprem↔vpc）
	•	VPC → Traffic Mirroring → Mirror filters → Create
	•	建 inbound/outbound 两条 accept + 兜底 reject（按你网段与方向填写）

6A）为每张 TGW attachment ENI 创建 Mirror Session
	•	VPC → Traffic Mirroring → Mirror sessions → Create
	•	Source：选择该 ENI
	•	Target：选择 NLB mirror target
	•	Filter：选择刚建的 filter
	•	（可选）VNI：建议统一指定一个值，方便探针侧解封装/分流（你后面要多来源汇总时很省事）
	•	相关 ENI 每张建一条 session

⸻

Phase 2B：接入 VGW 路径（推荐集中式 B1）

如果你决定走 B1（VGW Ingress Routing → GWLBE/GWLB → appliance），下面是控制台骨架步骤。

4B-1）创建 GWLB + appliance（汇聚点）
	•	EC2：准备 appliance 实例（每 AZ ≥ 1），关闭 source/dest check（如果它要转发）
	•	EC2：创建 Gateway Load Balancer，注册 appliance 实例
	•	VPC：创建 Endpoint Service（关联 GWLB）
	•	VPC：创建 VPC Endpoint，类型选 Gateway Load Balancer endpoint（GWLBE），每 AZ 建一个（常见做法）

4B-2）创建 VGW ingress route table 并把 next-hop 指向 GWLBE
	•	VPC → Route tables → Create rtb-vgw-ingress
	•	在该 route table 的 Edge association 里关联你的 VGW
	•	在该表中添加更精确的路由：
	•	Destination：业务子网 CIDR（更具体的优先）
	•	Target：GWLBE（vpce-xxxx）
	•	这正是 AWS 发布的能力点：VGW route table 支持把 GWLBE 作为 next-hop。 ￼

5B）镜像 appliance ENI（而不是 VGW）
	•	找到 appliance 实例的 ENI（EC2 → Network Interfaces）
	•	为这些 ENI 建 mirror session（同 Phase 2A 的 5A/6A）

⸻

五、探针侧实现要点（保证“比 1 分钟更实时”）

你要的实时性，主要由探针的 pipeline 决定：

1）解封装
	•	镜像流量是 VXLAN 封装。 ￼
	•	探针需要能 de-encapsulate VXLAN 并提取原始包。 ￼

2）秒级聚合（建议 5s/10s）
	•	每 5 秒滚动窗口输出：
	•	top src_ip（bytes、pps）
	•	top dst_ip / dst_port
	•	top 5-tuple
	•	这样你能在 10～30 秒内发出“DX 流量异常 + 嫌疑人榜”

3）富化（IP → 实例/业务）

为了让告警“可执行”，你需要把私网 IP 对应到实例/业务归属：
	•	定时拉取 ENI/实例清单（DescribeNetworkInterfaces/DescribeInstances），做本地缓存
	•	告警里输出 Name/ASG/Owner tag + 私网 IP

⸻

六、运维与自动化（你这类双路径环境很关键）

1）session 数控制
	•	TGW：通常 ENI 数量 = attachment AZ 数 × attachment 数（很可控）
	•	VGW（B1）：appliance ENI 数也可控
	•	尽量避免 VGW（B2）全量镜像业务 ENI，除非你只选少量关键实例

2）扩缩容自动跟随
	•	TGW attachment ENI 增减不频繁，但 VGW B1 的 appliance 可能扩缩容
	•	建议用一个小脚本/控制器（lambda/cron in your env 均可）根据 tag 自动：
	•	发现新增 ENI → 创建 mirror session
	•	发现下线 ENI → 删除 mirror session

3）容量规划建议
	•	镜像量只要放开就会非常大：一定用 filter 卡住 on-prem 网段与方向/端口
	•	NLB 后探针最好多 AZ，多实例；并做探针自身的丢包/处理时延指标（自建 Prometheus）

⸻

七、交付物清单（建议你按这个做项目化落地）
	1.	拓扑与镜像点清单
	•	TGW：列出每个 VPC attachment 的子网与对应 ENI
	•	VGW：选择 B1 或 B2；若 B1，列出 GWLBE、appliance 子网、appliance ENI
	2.	Mirror Filter 规则
	•	on-prem CIDR 列表、VPC CIDR 列表
	•	inbound/outbound、端口白名单、兜底 reject
	3.	探针规格与部署
	•	每 AZ 台数、实例类型、带宽预算
	4.	告警规则与消息模板
	•	触发条件（bps/pps/突增）
	•	输出字段（TopN + 实例富化）
	5.	自动化脚本
	•	ENI 发现/回收、session 创建/删除

⸻
