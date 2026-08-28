# NetBar 网络策略上下文

本文件统一 Direct Full 网络策略的领域术语。长期决策见 [2026-08-27 状态机 ADR](docs/2026-08-27-evidence-driven-network-policy-machine-adr.md) 与 [2026-08-28 underlay/overlay ADR](docs/2026-08-28-underlay-overlay-control-boundary-adr.md)。

## 不变量

- 连通性优先于偏好；Mini 是默认首选，但不能为了满足偏好破坏当前健康路径。
- NetBar 不开关 Wi-Fi，不修改 Mini 公司 DNS，不接管 Apple NAT/PF，不退出、重启或重载 Clash，也不操作其他 VPN/TUN。
- 只有用户在 `Clash 模式` Tab 点击后，NetBar 才可事务性修改唯一顶层 `enable_tun_mode` 标量和对应 Mihomo runtime TUN；网络事件与出口切换无权改变该模式。
- `utun` 成功不能证明底层物理出口；`forwarding=1` 也不能单独证明 MacBook 已能经 Mini 上网。
- App Store Lite 不包含 SSH、Helper、自动路由或 Mihomo 写动作。

## 事实层

- `ThunderboltLinkFacts`：`bridge0` 载波、`192.168.2.2/24`、Peer `192.168.2.1`。
- `MiniUpstreamFacts`：Mini `en0` 载波、预期 Manual 地址/路由、绑定上游探测。
- `MiniSharingFacts`：共享拓扑、Network Sharing 进程、内核 forwarding、Guardian generation 与新鲜度。
- `DownstreamEgressFacts`：MacBook 绑定 `bridge0` 的下游出口、实际物理路由、系统及 Clash HTTPS。
- `WiFiFacts`：无线电、关联、地址、网关、候选和当前数据面。
- `ServiceOrderFacts`：Wi-Fi/雷雳相对顺序、实际物理接口及系统收敛窗口。
- `DNSPathFacts`：服务级配置来源、scoped resolver、实际依赖接口、系统解析结果与 generation。DNS 值不证明雷雳链路，但 DNS 可用性参与端到端互联网证明。
- `ApplicationPathFacts`：系统代理感知 HTTPS、显式 Clash HTTPS、代理不感知/TUN HTTPS，以及不携带凭据的 ZCode 传输诊断。

事实必须携带 generation、采样时间、来源和有效期。来源矛盾用 `evidenceConflict` 表达，不能按字段优先级猜测。

## Mini 证明层级

1. `linkReady`：固定雷雳链路与 Peer 正常。
2. `upstreamReady`：Mini `en0` 地址、路由和自身上游正常。
3. `sharingLocallyReady`：共享拓扑、进程、forwarding 与新鲜 Guardian 全部正常。
4. `downstreamPreflightReady`：MacBook 绑定 `bridge0` 的下游探测通过。
5. `activeVerified`：Mini 服务顺序、实际 `bridge0` 出口、DNS 独立性、一次 Mihomo underlay 刷新及当前 Clash 模式的数据面均验证成功。

`degradedActive` 表示物理出口已经切到比失效 Mini 更安全的 Wi-Fi，但 DNS 或 overlay 尚未恢复。该状态不得宣称完整在线，也不得回滚到已知失效的 Mini。

纯 `NetworkPolicyMachine` 将上述证明作为 route generation 内的证据：旧 generation 结果直接丢弃，新 generation 到来时若存在未完成事务则先提出 rollback。Mini 自动切回只接受连续 30 秒完整证明；10 分钟内第二次切回失败在回滚后打开 10 分钟熔断。ZCode 诊断不进入路由证据指纹。

只有 `activeVerified` 可以显示“Mac mini 当前出口正常”。

当实际物理出口已经是 `bridge0` 或 Wi-Fi 时，同接口的新鲜 `activeVerified` 证明可以覆盖旧的 direct-bypass 失败分类；这用于保住公司网络下已经工作的 TUN/代理路径。它不能把尚未激活的候选直接提升为可切换状态，也不能覆盖载波、地址、共享进程或 forwarding 的明确故障。

## 动作所有权

- Mini Helper v4：只报告事实，或写入固定的下游失败标记；`apply/rollback` 只管理 Mini `bridge0` 固定地址。
- Mini Guardian：唯一有权保守重应用 Mini `en0` 既定 Manual 地址以及重拉原生 Network Sharing。
- Route Safety Helper v3：管理 Wi-Fi 与 `bridge0` 的相对服务顺序，并只在用户明确点击且 Wi-Fi DNS 精确依赖 `192.168.2.1` 时恢复自动 DNS；每次写入必须以 commit、rollback 或 manual recovery 结束。
- NetBar 策略机：读取事实、决定候选与事务，不直接持有管理员密码。
- Clash Overlay Controller：只响应用户模式命令；拥有 `enable_tun_mode` 与 runtime TUN 的窄写权限，并负责用户级事务回滚。
- Mihomo underlay 协作：物理出口确实变化时每个 route generation 最多清理一次现有连接；不改配置或 TUN 状态。
- ZCode 诊断：匿名 2xx–4xx 只证明端点传输可达，不是物理路由门禁，也不发送 OAuth token、Cookie 或账号信息。
