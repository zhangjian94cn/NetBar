# NetBar 网络策略上下文

本文件统一 Direct Full 网络策略的领域术语。长期决策见 [2026-08-27 状态机 ADR](docs/2026-08-27-evidence-driven-network-policy-machine-adr.md) 与 [2026-08-28 underlay/overlay ADR](docs/2026-08-28-underlay-overlay-control-boundary-adr.md)。

## 不变量

- 连通性优先于偏好；Mini 是默认首选，但不能为了满足偏好破坏当前健康路径。
- NetBar 不开关 Wi-Fi，不修改 Mini 公司 DNS，不接管 Apple NAT/PF，不退出或重启 Clash，也不操作其他 VPN/TUN。只有显式用户模式事务可通过原生界面激活已登记配置。
- 只有用户在 `Clash 模式` Tab 点击后，NetBar 才可编排双配置原生激活、TUN、系统代理与临时 DNS；策略由 dual-vpn-config 定义，节点由 clash-profile-compose 合成，网络事件与物理出口切换无权改变模式。
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
- Clash Network Mode Controller：只响应用户模式命令，验证稳定 profile UID、源摘要、完整运行规则、真实叶子、TUN、系统代理和DNS路径后完成；普通失败只回滚仍拥有的修改。legacy Overlay Controller保留旧两字段契约。
- Mihomo underlay 协作：物理出口确实变化时每个 route generation 最多清理一次现有连接；不改配置或 TUN 状态。
- ZCode 诊断：匿名 2xx–4xx 只证明端点传输可达，不是物理路由门禁，也不发送 OAuth token、Cookie 或账号信息。

## Mihomo 控制端发现

[MihomoControllerAccess](Sources/NetBar/Monitors/MihomoControllerAccess.swift) 是控制端发现与请求的唯一所有者。默认在当前用户服务 Socket、旧 Socket、本地 HTTP 之间有界验证；空配置及保存过的旧默认路径都使用自动发现，真正自定义 Socket/HTTP 独占选择。发现总预算 2 秒并继承恢复轮次预算，只复用本轮成功证据，失败保持可重试。自动结果不持久固定成用户偏好。

读取配置、流量快照和已有写动作共用已验证目标；写动作仍只允许 Unix Socket，失败不跨目标重试。控制请求绕过环境代理，日志只记录来源/验证结论，不含 Secret 或响应正文。

自动切回失败保留具体阶段及验证结果；退避不能一律归因于 Mini 上游抖动，成功切回后才清除上次失败。发现控制端成功不能替代路由和上网验证。

## NetBar 双配置与 DNS 生命周期

长期所有权与跨仓来源见 [infra 委托ADR](https://github.com/zhangjian94cn/zhangjian-skills/blob/main/skills/my/infra/docs/2026-10-22-netbar-profile-dns-delegation-adr.md)。策略不在Swift中复制；模式manifest位于用户Application Support/NetBar/ClashModes，真实UID是身份，名称只展示。初次通过Clash原生新建本地profile，禁止直接写profiles.current冒充激活。

[ClashNetworkModeController](Sources/NetBar/Monitors/ClashNetworkModeController.swift) 编排公司共存、统一出口、原网络；[受限原生适配器](Sources/NetBar/Monitors/LiveClashNetworkModeBackend.swift)只支持经验证的Clash版本。未知状态失败关闭；公司VPN必须用户手动断开，NetBar不代为断开或重连。

Route Safety Helper新增固定dns-status/prepare/acquire/release/reconcile协议7；[DNS恢复组件](Sources/NetBarDNSGuardian/main.swift)只管理本机物理服务DNS lease，保存服务UUID、原字典/自动来源、applied值、PID启动身份和私有检查和。模式互切不能覆盖首次基线。外部DNS改动保留，冲突manual_pending。恢复组件无Clash、VPN、物理路由或Mini写权限，无lease退出，不做周期网络probe。

**退出NetBar只恢复仍拥有的DNS，Clash配置、节点、TUN与系统代理全部保持。** 正常退出等待有界释放，强退/Clash退出由独立组件恢复；重开只读，绝不自动接管。统一配置仍运行但DNS未托管时明确“DNS保障已解除”。选择原网络才关闭TUN及系统代理。退出路径不能调用普通切换回滚。

DNS Helper protocol7 先在原生激活/TUN之前prepare保存原自动/手动来源（不写DNS、120秒预算），之后真实TUN UDP/TCP53劫持核验通过才获取。与Verge2.5.8共用114.114.114.114占位，不能另写地址触发两个写入方竞争。模式互切保留首次原件；普通失败先回滚Clash、准备记录等待6秒原生脚本宽限再CAS释放；进程退出仍只恢复DNS。公网统一出口需同一真实节点、无DIRECTfallback；公网IPv6经代理或失败，系统IPv6设置不动。内网/OA、浏览器自带DoH、真实DNS与流量、退出/强退/换网、Direct Full/Lite和能耗分别验收，不用文件/单测/菜单点击代替。

Guardian 启动保留 launchd 30 秒限速，固定 `kickstart -p` 请求最多 35 秒，App prepare/acquire 最多 45 秒；核对实际 root PID 和 executable，不能仅以已登记视为运行。租约替换事件刷新已有 watcher 的进程与期限，忽略自身最终值；不在每次获取时强制重启。启动失败保留原件日志，普通事务先回滚 Clash 再释放 DNS。
