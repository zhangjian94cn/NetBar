# NetBar 网络策略上下文

本文件统一 Direct Full 网络策略的领域术语。长期决策见 [2026-08-27 状态机 ADR](docs/2026-08-27-evidence-driven-network-policy-machine-adr.md) 与 [2026-08-28 underlay/overlay ADR](docs/2026-08-28-underlay-overlay-control-boundary-adr.md)。

## 不变量

- 连通性优先于偏好；Mini 是默认首选，但不能为了满足偏好破坏当前健康路径。
- NetBar 不开关 Wi-Fi，不修改 Mini 公司 DNS，不接管 Apple NAT/PF，不退出或重启 Clash，也不操作其他 VPN/TUN。Clash 的配置、TUN、代理和 DNS 完全由 Clash 原生管理。
- `Clash` Tab 只读观察与显式有界检测；策略由 dual-vpn-config 定义，节点由 clash-profile-compose 合成，原生激活及系统 DNS 归 Clash。NetBar 生命周期不改网络。
- `utun` 成功不能证明底层物理出口；`forwarding=1` 也不能单独证明 MacBook 已能经 Mini 上网。
- App Store Lite 不包含 SSH、Helper、自动路由或 Mihomo 写动作。

## 事实层

- `ThunderboltLinkFacts`：`bridge0` 载波、独立管理别名 `10.254.254.2/30`、Peer `10.254.254.1`，以及 Apple Internet Sharing 动态分配的数据面 DHCP 地址与网关。管理 Peer 只证明恢复通道，不能冒充共享网关。
- `MiniUpstreamFacts`：Mini `en0` 载波、预期 Manual 地址/路由、绑定上游探测。
- `MiniSharingFacts`：共享拓扑、Network Sharing 进程、内核 forwarding、Guardian generation 与新鲜度。
- `DownstreamEgressFacts`：MacBook 绑定 `bridge0` 的下游出口、实际物理路由、系统及 Clash HTTPS。
- `WiFiFacts`：无线电、关联、地址、网关、候选和当前数据面。
- `ServiceOrderFacts`：Wi-Fi/雷雳相对顺序、实际物理接口及系统收敛窗口。
- `DNSPathFacts`：服务级配置来源、scoped resolver、实际依赖接口、系统解析结果与 generation。DNS 值不证明雷雳链路，但 DNS 可用性参与端到端互联网证明。
- `ApplicationPathFacts`：系统代理感知 HTTPS、显式 Clash HTTPS、代理不感知/TUN HTTPS，以及不携带凭据的 ZCode 传输诊断。

事实必须携带 generation、采样时间、来源和有效期。来源矛盾用 `evidenceConflict` 表达，不能按字段优先级猜测。

## Mini 证明层级

1. `linkReady`：独立 `/30` 管理链路与 Peer 正常，雷雳网络服务保持 DHCP。
2. `upstreamReady`：Mini `en0` 地址、路由和自身上游正常。
3. `sharingLocallyReady`：共享拓扑、进程、forwarding 与新鲜 Guardian 全部正常。
4. `downstreamPreflightReady`：MacBook 绑定 `bridge0` 的下游探测通过。
5. `activeVerified`：Mini 服务顺序、实际 `bridge0` 出口、DNS 独立性、一次 Mihomo underlay 刷新及当前 Clash 模式的数据面均验证成功。

`degradedActive` 表示物理出口已经切到比失效 Mini 更安全的 Wi-Fi，但 DNS 或 overlay 尚未恢复。该状态不得宣称完整在线，也不得回滚到已知失效的 Mini。

纯 `NetworkPolicyMachine` 将上述证明作为 route generation 内的证据：旧 generation 结果直接丢弃，新 generation 到来时若存在未完成事务则先提出 rollback。Mini 自动切回只接受连续 30 秒完整证明；10 分钟内第二次切回失败在回滚后打开 10 分钟熔断。ZCode 诊断不进入路由证据指纹。

只有 `activeVerified` 可以显示“Mac mini 当前出口正常”。

当实际物理出口已经是 `bridge0` 或 Wi-Fi 时，同接口的新鲜 `activeVerified` 证明可以覆盖旧的 direct-bypass 失败分类；这用于保住公司网络下已经工作的 TUN/代理路径。它不能把尚未激活的候选直接提升为可切换状态，也不能覆盖载波、地址、共享进程或 forwarding 的明确故障。

Wi-Fi 是当前出口时，Mini Helper 的 `ready` 只允许进入 30 秒资格确认和事务性试切。NetBar 对出口失败只做本地回退，不向 Mini 报告，Mini 也不会因此重启 Internet Sharing。

## 动作所有权

- Mini Helper v5：只接受 `status/prepare/migrate/rollback/finalize-rollback` 五个固定命令；迁移管理别名与 `bridge0` DHCP 契约，不写 Apple NAT/DHCP 私有配置。
- Mini Guardian：维护 Mini 管理别名并观察 `en0`、Apple Internet Sharing、forwarding 与共享数据面；对 Apple 共享进程只观察不干预（不发信号、不 kickstart），不重写公司 DNS、NAT/DHCP 或 VPN。共享总开关关闭立刻 `manual_pending`；开着但未在服务时先报恢复中，90 秒后才 `manual_pending` 并点名原因。
- Route Safety Helper 基础协议 v5：管理 Wi-Fi 与 `bridge0` 的相对服务顺序、补回本机管理别名，并只在用户明确点击且 Wi-Fi DNS 精确依赖 `192.168.2.1` 时恢复自动 DNS；每次事务必须以 commit、rollback 或 manual recovery 结束。
- NetBar 策略机：读取事实、决定候选与事务，不直接持有管理员密码。
- Clash Network Mode Controller：只读真实 UID、源/运行规则与 DNS/TUN 摘要、真实节点及代理；配置符合与探测证据分开。无 AX、模式/TUN/节点/DNS 写动作。
- Mihomo underlay 协作：物理出口确实变化时每个 route generation 最多清理一次现有连接；不改配置或 TUN 状态。
- ZCode 诊断：匿名 2xx–4xx 只证明端点传输可达，不是物理路由门禁，也不发送 OAuth token、Cookie 或账号信息。

## Mihomo 控制端发现

[MihomoControllerAccess](Sources/NetBar/Monitors/MihomoControllerAccess.swift) 是控制端发现与请求的唯一所有者。默认在当前用户服务 Socket、旧 Socket、本地 HTTP 之间有界验证；空配置及保存过的旧默认路径都使用自动发现，真正自定义 Socket/HTTP 独占选择。发现总预算 2 秒并继承恢复轮次预算，只复用本轮成功证据，失败保持可重试。自动结果不持久固定成用户偏好。

读取配置、流量快照和已有写动作共用已验证目标；写动作仍只允许 Unix Socket，失败不跨目标重试。控制请求绕过环境代理，日志只记录来源/验证结论，不含 Secret 或响应正文。

自动切回失败保留具体阶段及验证结果；退避不能一律归因于 Mini 上游抖动，成功切回后才清除上次失败。发现控制端成功不能替代路由和上网验证。

## Clash 原生双配置与只读监控

长期所有权及来源见 [infra 委托 ADR](https://github.com/zhangjian94cn/zhangjian-skills/blob/feature/netbar-clash-dns/skills/my/infra/docs/2026-10-22-netbar-profile-dns-delegation-adr.md)。manifest v2 的真实 UID 是身份；v1 仅迁移识别。节点/规则/DNS 仍由 Skills 拥有，NetBar 只验证，不重复定义。

两份 profile 共用原生设置：保留 stack/device/MTU；自动路由/出口检测开、严格路由关、UDP/TCP53 劫持；现代排除字段保留公司/LAN/Tailscale/管理端点。root IPv6=true 保留 IPv6 TUN；DNS IPv6=false，无 IPv6 Fake-IP 池；明确例外后拒绝公网 IPv6，关闭 ICMP 转发。局部脚本只钳制 Verge 派生 DNS 字段，DNS 覆写关闭。系统 IPv6 不动。

[只读观察器](Sources/NetBar/Monitors/ClashNetworkModeController.swift) 的 backend 无任何配置写方法。读取与显式检测单飞，不在启动自动探测。检测绑定配置、节点和网络指纹，五分钟内且身份不变才显示新鲜；网络事件清除旧结果。配置符合不能代替 DNS/流量/IPv6/公司业务证据。统一配置下公司隧道活动或未知时显示保障条件不足，不操作 VPN。

面板只有刷新状态、检测当前网络、打开 Clash。退出/强退/重开 NetBar 不改网络，无辅助功能权限。旧 AX 适配器、Overlay TUN writer、DNS 租约/Guardian 已从源码及打包删除。原 Mini Guardian 与基础路由 Helper 保留。

一次性 [退役维护](Sources/NetBar/Resources/RouteSafetyHelper/retire-netbar-dns-experiment.command) 仅在旧租约 inactive、TUN/代理关、DNS 原件核实后撤销 DNS 动作、卸载 DNS launchd 并私有备份组件；不写 DNS 或 Clash。基础路由动作逐字保留，外部变化 manual_pending。

Clash 正常关 TUN/退出后核对逐服务 DNS；极端崩溃的恢复路径是重新打开 Clash 再关闭 TUN，不承诺后台自动恢复。只有 Clash 正常、TUN 有效及本轮证据通过时才谈分流保障。历史失败在 infra Spec validation 保留，不能将旧实验测试当作新版本验收。

## 四 Tab 产品界面

保留出口、Clash、应用、监控四个底部 Tab，Direct Full 为 340×460pt，Lite 为 340×390pt 并按既有能力裁剪；设置保留独立单实例窗口。用户在 2026-10-23 明确取消单页总览及侧栏详情方向，该方向从未安装。正式约束见 [Spec 006](https://github.com/zhangjian94cn/zhangjian-skills/blob/feature/netbar-product-experience/skills/my/infra/local-dev-config/netbar-app-management/specs/006-product-experience/spec.md)，当前视觉验收见 [design-qa](design-qa.md)。

- 顶部物理连通性、配置事实与显式检测分开；未检测、过期、条件不足保持中性。DNS/HTTPS 通过仅证明对应两项。
- 应用流量只使用近期连接证据判定路由，只有接口信息时待确认；累计数据不被当前路由重新归因。
- VPS 的最近尝试与最近成功分开，首次失败不填零，缺少配额不显示无限制；草稿测试不提前保存，关闭时保护未保存输入。
- 一套协调器监听网络身份。仅面板应用页可见时提升进程明细采样，独立设置不创建监控实例；继续执行前台至少 2 秒、后台至少 10 秒和失败退避。
- DEBUG 原生预览使用独立 bundle、偏好与 Keychain service，不写路由策略或流量历史。重建后旧预览钥匙串授权不可交互时返回凭据缺失，避免验收窗口等待旧签名授权；不改变正式凭据行为。
