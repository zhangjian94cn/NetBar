# NetBar 网络策略上下文

本文件统一 Direct Full 网络策略的领域术语。长期决策见 [2026-08-27 ADR](docs/2026-08-27-evidence-driven-network-policy-machine-adr.md)。

## 不变量

- 连通性优先于偏好；Mini 是默认首选，但不能为了满足偏好破坏当前健康路径。
- NetBar 不开关 Wi-Fi，不修改 Mini 公司 DNS，不接管 Apple NAT/PF，不退出、重启、重载或改写 Clash，也不操作其他 VPN/TUN。
- `utun` 成功不能证明底层物理出口；`forwarding=1` 也不能单独证明 MacBook 已能经 Mini 上网。
- App Store Lite 不包含 SSH、Helper、自动路由或 Mihomo 写动作。

## 事实层

- `ThunderboltLinkFacts`：`bridge0` 载波、`192.168.2.2/24`、Peer `192.168.2.1`。
- `MiniUpstreamFacts`：Mini `en0` 载波、预期 Manual 地址/路由、绑定上游探测。
- `MiniSharingFacts`：共享拓扑、Network Sharing 进程、内核 forwarding、Guardian generation 与新鲜度。
- `DownstreamEgressFacts`：MacBook 绑定 `bridge0` 的下游出口、实际物理路由、系统及 Clash HTTPS。
- `WiFiFacts`：无线电、关联、地址、网关、候选和当前数据面。
- `ServiceOrderFacts`：Wi-Fi/雷雳相对顺序、实际物理接口及系统收敛窗口。

事实必须携带 generation、采样时间、来源和有效期。来源矛盾用 `evidenceConflict` 表达，不能按字段优先级猜测。

## Mini 证明层级

1. `linkReady`：固定雷雳链路与 Peer 正常。
2. `upstreamReady`：Mini `en0` 地址、路由和自身上游正常。
3. `sharingLocallyReady`：共享拓扑、进程、forwarding 与新鲜 Guardian 全部正常。
4. `downstreamPreflightReady`：MacBook 绑定 `bridge0` 的下游探测通过。
5. `activeVerified`：Mini 服务顺序、实际 `bridge0` 出口、一次 Mihomo underlay 刷新及系统/Clash HTTPS 均验证成功。

只有 `activeVerified` 可以显示“Mac mini 当前出口正常”。

## 动作所有权

- Mini Helper v4：只报告事实，或写入固定的下游失败标记；`apply/rollback` 只管理 Mini `bridge0` 固定地址。
- Mini Guardian：唯一有权保守重应用 Mini `en0` 既定 Manual 地址以及重拉原生 Network Sharing。
- Route Safety Helper：只管理 Wi-Fi 与 `bridge0` 的相对服务顺序；未来 v2 通过事务日志 commit/rollback。
- NetBar 策略机：读取事实、决定候选与事务，不直接持有管理员密码。
- Mihomo：物理出口确实变化时每个 route generation 最多清理一次现有连接；不改配置或 TUN 状态。
