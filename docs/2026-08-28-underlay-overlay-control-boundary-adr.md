# ADR: 物理出口与 Clash 模式使用独立控制域

- 日期: 2026-08-28
- 状态: accepted（UI 与事务已启用；纯网络策略机仍按影子门禁推进）
- 范围: NetBar Direct Full / underlay 故障转移、Clash overlay 手动模式与路由事务
- 相关源码: [NetworkPolicyMachine.swift](../Sources/NetBar/Monitors/NetworkPolicyMachine.swift)、[NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)、[ClashOverlayModeController.swift](../Sources/NetBar/Monitors/ClashOverlayModeController.swift)、[NetworkControlTabs.swift](../Sources/NetBar/Views/Components/NetworkControlTabs.swift)、[Route Safety Helper](../Sources/NetBar/Resources/RouteSafetyHelper/netbar-route-safety-helper)
- 部分取代: [证据驱动网络策略 ADR](2026-08-27-evidence-driven-network-policy-machine-adr.md) 中“NetBar 对 Clash 配置和 TUN 完全只读”的边界；不改变其 24 小时影子验证与接管门禁
- 上位原则: [engineering-principles.md](../../../docs/engineering-principles.md)

## Context and Problem Statement

雷雳、Internet Sharing、Wi-Fi 服务顺序属于物理出口（underlay）；系统代理与 TUN 属于 Clash 数据面（overlay）。旧界面把两类状态放在同一卡片里，网络出口变化又可能被误解为应自动开关 TUN。现场故障证明，关闭 TUN 可以作为有效止血，但 Mini 公司 VPN、`forwarding=0`、旧 Mihomo 连接和物理路由漂移都可能分别造成下游失败，不能把 TUN 当作唯一根因。

同时，Route Safety Helper v1 在成功写入后仍保留备份，无法区分“已提交状态”和“应用在验证前退出”。Clash 模式若只改 runtime 或只改 `verge.yaml`，重启后也会重新漂移。

## Decision Drivers

- 用户选择的 Clash 模式必须在 Mini/Wi-Fi 故障转移期间保持不变。
- Overlay 失败不能反向驱动 underlay 在两个健康候选间来回切换。
- 物理出口真实变化后需要让 Mihomo 新连接重新绑定，但每个变化只能清理一次旧连接。
- TUN 模式必须同时满足持久配置、runtime、系统代理、共存排除规则与数据面验证。
- 普通操作不能要求管理员密码；App Store Lite 不得携带这些写入能力。
- 每次路由写入必须有 commit、rollback 或明确的 manual recovery 终态。

## Considered Options

1. 继续用一个控制器同时判断出口和 TUN。改动小，但 overlay 故障会继续污染物理路由决策。
2. 网络故障时自动切成系统代理，恢复后自动打开 TUN。短期可能恢复，但会覆盖用户意图，并把公司 VPN 与 TUN 的交互变成循环动作。
3. 将 underlay 与 overlay 拆成两个 Tab 和两个控制器；只用物理出口变化事件触发一次 Mihomo 连接刷新，Clash 模式只接受用户操作。
4. 完全不提供 TUN 模式切换，继续要求用户打开 Clash 操作。权限最小，但无法提供可回滚、可验证的一致事务。

## Decision Outcome

采用方案 3。`网络出口` Tab 只管理 Mini/Wi-Fi 偏好、链路事实、候选、服务顺序和故障转移；`Clash 模式` Tab 只提供用户触发的 `系统代理` 与 `TUN 全局`。NetBar 不因断线、插线、VPN 变化或自动回退而改变 TUN。

Clash 模式事务严格只修改顶层唯一 `enable_tun_mode` 标量，并通过 Mihomo Unix Socket PATCH 对应 runtime TUN。事务先保存 SHA-256 备份和原权限，再依次验证 runtime、持久值、指向当前 mixed-port 的 loopback 系统代理、显式代理 HTTPS 与系统 HTTPS；失败按相反顺序恢复。`TUN 全局` 额外要求 `ipv6=false` 以及 aTrust、LAN、Tailscale、WireGuard 共存排除基线。其他 Clash 字段仍由 `dual-vpn-config` 独占。

Route Safety Helper 在本决策中升级为协议 v2。`prefer-*` 写入完整原服务顺序和 pending target；NetBar 完成实际路由及数据面验证后必须调用 `commit`，失败调用 `rollback`。启动时发现 pending 事务会重新验证后提交或恢复。v1 只留下备份、没有 pending target 的状态在一次性安装时视作已提交遗留并清理；v2 pending 事务绝不由安装器删除。其后续 v3 DNS 窄权限与回滚边界见 [端到端 DNS ADR](2026-08-28-end-to-end-dns-overlay-failover-adr.md)。

## Consequences

- 正面：用户能明确区分“走哪条物理路径”和“Clash 如何接管流量”，网络切换不再偷偷改变 TUN。
- 正面：Clash 文件、runtime 和数据面作为一个用户级事务提交，不需要管理员授权，也不重启 Clash。
- 正面：应用在路由验证中退出后可以恢复事务，不再把半完成服务顺序当作稳定状态。
- 正面：App Store Lite 通过条件编译和产物字符串门禁排除 Clash 写入与 Helper 能力。
- 代价：Direct Full 获得一个非常窄的 Clash 配置写权限，必须与 `dual-vpn-config` 保持字段所有权契约。
- 代价：从 Route Helper v1 升级到 v2 需要一次管理员安装；之后固定命令由精确 sudoers 无密码执行。
- 限制：如果配置文件在事务期间被其他程序修改，NetBar fail closed，不覆盖外部变更，并要求用户重新检测。
- 限制：Overlay 数据面失败只报告和回滚模式事务；除非 underlay 本身也失败且另一候选已验证健康，否则不触发物理出口切换。

## Verification and Rollout

- [ClashOverlayModeControllerTests.swift](../Tests/NetBarTests/ClashOverlayModeControllerTests.swift) 覆盖唯一标量、备份、外部修改冲突、runtime 失败、数据面失败、回滚、成功提交和重复点击无副作用。
- [NetworkRoutePolicyTests.swift](../Tests/NetBarTests/NetworkRoutePolicyTests.swift) 覆盖 Helper v3 固定命令、路由/DNS commit/rollback 终态及物理出口变化的单次连接刷新。
- [build-appstore.sh](../scripts/build-appstore.sh) 验证 Lite 产物不携带 Helper、SSH 或 Clash 模式写入实现。
- 纯 `NetworkPolicyMachine` 仍必须先只读影子运行 24 小时；该门禁通过前，本文不授权其接管真实路由副作用。
