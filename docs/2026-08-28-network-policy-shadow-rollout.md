# NetworkPolicyMachine 只读影子运行手册

- 日期: 2026-08-28
- 状态: opt-in / 接管门禁未满足（自 2026-08-29 起默认关闭，见 [默认关闭 ADR](2026-08-29-network-policy-shadow-default-off-adr.md)）
- 范围: NetBar Direct Full 网络出口状态机
- 相关源码: [影子协调器](../Sources/NetBar/Monitors/NetworkPolicyShadowCoordinator.swift)、[纯状态机](../Sources/NetBar/Monitors/NetworkPolicyMachine.swift)、[旧执行控制器](../Sources/NetBar/Monitors/NetworkModeController.swift)、[影子测试](../Tests/NetBarTests/NetworkPolicyShadowCoordinatorTests.swift)
- 相关决策: [证据驱动状态机 ADR](2026-08-27-evidence-driven-network-policy-machine-adr.md)、[underlay/overlay 边界 ADR](2026-08-28-underlay-overlay-control-boundary-adr.md)

## 目的与边界

影子期用于比较纯 reducer 的提议与当前生产控制器的实际稳定结果。`NetworkPolicyShadowCoordinator` 是 actor，串行接收事实；它没有 Route Helper、Mini Helper、Mihomo 或配置写入依赖，所有 `NetworkPolicyEffect` 都只会成为诊断日志中的 proposal。

旧 `NetworkModeController` 在影子期继续是唯一真实副作用所有者。24 小时门禁未满足前，不得把 proposal 接到任何执行器，也不得因为影子分歧自动改变 Mini/Wi-Fi 或 Clash 模式。

## 如何开启一次观察窗口

影子运行默认关闭。开窗观察时二选一：

- 临时运行：以 `NETBAR_POLICY_SHADOW=1` 启动 NetBar。
- 持续观察：把 `AppConfig.networkPolicyShadowEnabled` 置为 `true`（UserDefaults key `network_policy_shadow_enabled`）。

开关只决定 `MonitorCoordinator` 是否构造 `NetworkPolicyShadowCoordinator`；关闭时 `NetworkModeController.policyShadow` 为 `nil`，与该参数从未传入等价。窗口结束后请关闭，避免无人复核的观察继续写日志。

## Generation 与收敛

- SCDynamicStore 和 CoreWLAN 的连续通知合并 250 ms，只形成一个 generation，并在合并后触发一次强制采样。
- Mini Guardian、公司 VPN 或共享事实发生实质变化时，即使没有本地路由通知，也会形成新 generation。
- reducer 的 transaction ID、deadline 和 idempotency key 随 proposal 记录；旧 generation 的结果由纯状态机拒绝。
- 相同 generation 的重复快照不能重复生成切换 proposal；昨夜重复故障轨迹通过 `network-trace-replay` 验证为有界副作用。

## 日志与审阅

日志位置为 `~/Library/Logs/NetBar/network-events.jsonl`，影子事件只有：

- `network_policy_shadow_generation`
- `network_policy_shadow_observation`
- `network_policy_shadow_proposal`

日志不包含 SSID、BSSID、密码、公司 DNS 或代理凭据。观察窗口必须覆盖雷雳拔插、睡眠唤醒、Mini `en0`/Internet Sharing 故障与恢复、Mini 公司 VPN、Wi-Fi 变化，以及“系统代理”和“TUN 全局”两种 overlay。

2026-08-28 起，影子 observation 还包含不落原始 resolver 值的 DNS 依赖分类、系统解析、系统/显式 Clash/代理不感知数据面和 ZCode 匿名传输布尔值。只有前五项参与 route generation；ZCode 只改变诊断 observation，不产生 route proposal。影子 reducer 会验证 `routeEligible → degradedActive` 的安全 Wi-Fi 回退、Mini 30 秒资格、两次失败熔断，以及新 generation 对未完成事务的 rollback 不变量；它仍不持有 Helper 或 Mihomo executor。

## 接管门禁

接管 PR 只能在以下条件都有可复核证据后开始：

1. 连续运行至少 24 小时，进程与日志没有中断。
   任何改变候选证明优先级、generation 或 reducer effect 的新构建都会重新开始这 24 小时窗口，不能拼接旧构建的观察时长。
2. 所有明确 Mini 故障都只提议一次安全 Wi-Fi 回退；健康当前路径不会因为首选路径 `unknown` 被破坏。
3. Mini 恢复未连续获得 30 秒完整证明时，不提议切回。
4. 没有 underlay proposal 试图修改用户选择的 Clash 模式。
5. proposal 与旧控制器不一致时逐条分类；任何可能造成离线、抖动或错误回滚的分歧都必须先修复并重新开始观察窗口。
6. Route Safety Helper 已是协议 v3，且路由和 DNS 现场事务都能落到 commit、rollback 或明确 manual recovery。

本文件的存在不代表门禁已经通过。通过后必须追加观察起止时间、覆盖事件、日志摘要、安装二进制 SHA-256 和审阅结论；在此之前 PR 4 保持 `manual_pending`。

## 现场校正：链路证明不包含 DNS 值

首次影子部署发现 `bridge0` 载波、固定地址、Peer 和绑定 TLS 全部正常，但 MacBook 雷雳服务使用外部 DNS 时，旧快照仍因“DNS 不包含 `192.168.2.1`”误报未初始化。DNS 选择不证明雷雳载波、静态地址或 Peer，也可能是公司环境的受保护配置。因此 [LiveNetworkModeSystemProvider](../Sources/NetBar/Monitors/NetworkModeController.swift) 和固定链路验证不再读取 DNS 来决定 `ThunderboltLinkState`。端到端互联网证明仍必须单独采集 [DNSPathFacts](../Sources/NetBar/Monitors/NetworkConnectivity.swift)；只有 Wi-Fi 精确依赖失联 Mini 地址时，才向用户提供可回滚的自动 DNS 修复。详见 [端到端 DNS ADR](2026-08-28-end-to-end-dns-overlay-failover-adr.md)。
