# ADR: 端到端 DNS、overlay 与物理出口故障转移

- 日期: 2026-08-28
- 状态: accepted（Route Safety Helper v3/v4 部分已由 v5 supersede）
- 范围: NetBar Direct Full / DNS 证据、Route Safety Helper、应用链路诊断
- 相关源码: [NetworkConnectivity.swift](../Sources/NetBar/Monitors/NetworkConnectivity.swift)、[NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)、[NetworkLinkProvisioner.swift](../Sources/NetBar/Monitors/NetworkLinkProvisioner.swift)、[Route Safety Helper](../Sources/NetBar/Resources/RouteSafetyHelper/netbar-route-safety-helper)、[NetworkModeCard.swift](../Sources/NetBar/Views/Components/NetworkModeCard.swift)
- 部分取代: [underlay/overlay 控制边界 ADR](2026-08-28-underlay-overlay-control-boundary-adr.md) 中 Route Safety Helper v2 协议，以及 [影子发布说明](2026-08-28-network-policy-shadow-rollout.md) 中“DNS 只在激活后由 HTTPS 间接验证”的表述

## Context and Problem Statement

固定雷雳链路的成立不依赖 DNS，但“应用真正能联网”必须包含 DNS 证据。历史配置曾让 Wi-Fi 手动使用 Mini 地址 `192.168.2.1` 作为解析器：雷雳断开后，macOS 即使已经把默认物理出口切到 Wi-Fi，浏览器、ZCode 和 CLI 仍可能因解析链路失效而超时。与此同时，浏览器会使用系统代理，而不遵循系统代理的后台程序通常依赖 TUN；用任一应用的结果概括整台机器会混淆物理出口、DNS 与 overlay 故障。

普通插拔时静默重写 DNS 会覆盖用户的公司网络配置；把 ZCode OAuth 端点作为路由门禁又会让单一服务端故障触发错误切换。需要在保留用户配置所有权的前提下，把这些事实加入端到端证明。

## Decision Drivers

- 明确失效的 Mini 不能因为 Wi-Fi 的 DNS 或 TUN 尚未收敛而重新成为物理出口。
- 固定雷雳的载波、地址和 Peer 证明必须与 DNS 值解耦。
- 只有精确的 Mini 依赖 DNS 可以由 NetBar 在用户点击后事务化修复。
- 网络出口变化不能自动改变用户选择的 Clash 模式。
- ZCode 需要专项诊断，但不能拥有物理路由决策权。
- App Store Lite 保持只读，且任何日志都不能暴露 DNS、SSID 或账号凭据。

## Considered Options

1. 每次切换或插拔都把 Wi-Fi DNS 改成自动。实现简单，但会覆盖公司 DNS，并把 underlay 事件扩大成不相关的配置写入。
2. 完全忽略 DNS，仅使用默认路由与 HTTPS。无法解释“路由已回 Wi-Fi，但解析器仍指向失联 Mini”的真实故障。
3. 把 ZCode 登录成功作为全局 readiness。能覆盖一个用户场景，但服务端或 OAuth 故障会污染全局网络策略。
4. 将 DNS 和应用路径建模为独立事实，只对精确的 Mini 依赖 DNS提供用户触发、可回滚修复。

## Decision Outcome

采用方案 4。`DNSPathFacts` 记录服务、配置来源、scoped resolver、依赖分类、系统解析与采样 generation；`ApplicationPathFacts` 分开记录系统代理感知、显式 Clash、代理不感知/TUN 和 ZCode 匿名传输诊断。物理候选依次获得 `routeEligible`、`preflightEligible`、`activeVerified` 或 `degradedActive` 证明。

对于已经是实际物理出口的路径，最新的 `activeVerified` 端到端证明优先于旧的“绑定接口直连 HTTPS 失败”分类。公司网络可能限制 direct bypass，而 TUN/代理数据面仍完整可用；这种情况下不得仅因 `boundEgressUnavailable`、远端状态暂时未知或证据冲突就拆掉当前健康路径。该优先级只适用于已经激活且物理接口一致的路径，不得用于资格确认一个尚未切入的候选；明确的载波、地址、sharing 或 forwarding 故障仍然 fail closed。

当当前出口是 Wi-Fi 时，Mini Helper 的新鲜 `ready` 原始事实只把 Mini 提升为“可进行事务性试切”的候选；公司网络下的 direct-bypass 失败不能触发 `report-egress-failure`。下游失败报告只允许来自已经激活为实际物理出口的 Mini 路径，否则报告会驱动 Guardian 重拉本来健康的 Internet Sharing，形成“预检失败 → 重拉共享 → 证据冲突 → 再次预检”的反馈环。试切后仍必须用实际 `bridge0` 出口及系统、Clash、TUN 数据面验证，失败立即 rollback Wi-Fi。

Mini 明确断线或下游共享失效时，只要 Wi-Fi 具备载波、IPv4 和网关，就允许提交 Wi-Fi 物理路由。DNS 或 overlay 未恢复时显示 `degradedActive`，不得回滚到已知失效的 Mini。若原路径仍健康，目标路径验证失败仍按原事务回滚。

Route Safety Helper 最初升级到 v3 并增加唯一固定命令 `repair-wifi-dns`；地址面拆分后由 v4 继续拥有该事务，并增加固定命令 `ensure-management-alias`。2026-08-30 的 [公司 VPN 与旧 Mini DNS 决策](2026-08-30-company-vpn-diagnostics-and-targeted-dns-cleanup-adr.md) 将协议升级为 v5：保留“恢复自动 DNS”作为独立动作，同时增加只删除精确旧地址的 `remove-legacy-mini-dns`。Helper 动态识别 Wi-Fi 服务，原值、服务身份与 SHA-256 保存到 root-only 事务记录。NetBar 验证 resolver 和数据面后 `commit`，否则 `rollback`；普通网络事件不调用任何 DNS 写命令。

固定链路初始化继续保存和恢复原 DNS，但新固定配置保留本机雷雳服务的原 DNS，`verifyFixedLink` 只验证 `bridge0` 地址、载波和 Peer。Mini 公司 DNS、Clash DNS/Fake-IP 与 Internet Sharing DNS proxy 始终在 Helper 写入边界之外。

TUN 全局是新安装的推荐模式，现有用户选择不迁移，网络切换也不自动开关 TUN。ZCode 诊断只发送无凭据请求；DNS、TCP/TLS 成功且匿名响应为 2xx–4xx 即视为传输可达，其结果只用于专项提示。

## Consequences

- 正面：雷雳断开后能把物理路由安全地留在 Wi-Fi，即使解析或 TUN 暂时降级，也不会回滚到断开的 Mini。
- 正面：用户能区分“DNS 仍依赖 Mini”“系统代理可用但代理不感知应用不可用”和“ZCode 端点不可达”。
- 正面：DNS 修复是一次性用户动作，安装 Helper v3 后不再需要日常管理员授权，并能恢复原配置。
- 代价：端到端探测次数增加，UI 必须表达“受限在线”，不能把物理路由成功等同于完整在线。
- 代价：事实 generation 与纯状态机接管仍需经过 24 小时影子验证；在门禁完成前，新增证据先用于诊断和旧控制器的窄范围安全修复。
- 风险边界：任意其他手动 DNS、公司 DNS、ZCode 业务响应或单次公网目标失败都不得触发自动写入或物理路由抖动。
