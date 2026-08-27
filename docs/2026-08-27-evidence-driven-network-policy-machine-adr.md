# ADR: 证据驱动的端到端网络策略状态机

- 日期: 2026-08-27
- 状态: accepted（分阶段启用）
- 范围: NetBar Direct Full / Mini 共享自愈、MacBook 路由事务与数据面验证
- 相关源码: [NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)、[MacMiniLinkProfile.swift](../Sources/NetBar/Monitors/MacMiniLinkProfile.swift)、[Mini Guardian](../Sources/NetBarMiniNetworkGuardian/main.swift)、[Guardian 恢复规划器](../Sources/NetBarMiniNetworkGuardianSupport/RecoveryPlanner.swift)、[Mini Helper](../Sources/NetBar/Resources/MiniLinkHelper/netbar-mini-link-helper)、[诊断命令](../scripts/network-readiness-diagnostics.sh)
- 取代范围: [Mac mini 优先路由 ADR](2026-08-26-mac-mini-preferred-route-self-healing-adr.md) 中“共享进程运行即可支撑 ready”的判断，以及 [候选故障转移 ADR](2026-08-26-connectivity-first-candidate-failover-adr.md) 中由大型控制器直接交织证据、动作和 UI 的实现选择
- 上位原则: [engineering-principles.md](../../../docs/engineering-principles.md)

## Context and Problem Statement

2026-08-27 的实机故障中，Mini 固定雷雳链路、`en0` 载波、地址、路由和 Mini 自身公网探测均正常，`com.apple.NetworkSharing` 也显示 running，但 `net.inet.ip.forwarding=0`，MacBook 无法经 `bridge0` 出口访问公网。旧 Mini Helper 又因 `set -o pipefail` 与 `ps | grep -q` 的 SIGPIPE 组合把正在运行的共享进程稳定误报为停止，造成 Helper 与 Guardian 长时间矛盾。

控制器把这些字段压缩成一个 `gatewayState`，且降级计时从“成功切到 Wi-Fi”才开始。当 Wi-Fi 候选不可用时，它持续按 10 秒节奏重复回退和日志动作，不能收敛为稳定事实状态。内部一致的快照测试没有覆盖跨来源矛盾、旧异步结果、内核转发关闭和未完成路由事务。

## Decision Drivers

- 连接可用性高于出口偏好；只有完整端到端证明才允许宣称 Mini 正常。
- 进程、内核转发、共享拓扑、Mini 上游、MacBook 下游、物理路由和 Clash 数据面是正交证据，不得互相替代。
- 同一网络 generation 的动作必须串行、幂等且有终态；旧 generation 的结果不得改变新状态。
- Wi-Fi 候选不可用是一个稳定等待状态，不能成为周期性副作用风暴。
- Mini 公司 DNS、Apple NAT 所有权、Clash 配置以及其他 VPN/TUN 继续位于 NetBar 写入边界之外。
- 高风险接管必须经过止血、影子验证和可回退启用，而不是一次替换全部策略。

## Considered Options

1. 只修复 Helper 的进程布尔值。能去掉一项假阴性，但仍会把 forwarding=0 或下游 NAT 故障误判为 ready。
2. 让 Guardian 直接依据 MacBook 报告反复重启共享。扩大远端写入面，且无法解决控制器并发和旧结果覆盖。
3. 继续增加 `NetworkModeController` 条件分支。短期改动小，但证据读取、决策、副作用和 UI 会继续互相影响。
4. 先交付受限止血，再引入纯 reducer、generation 证据和事务性 Helper；影子验证通过后成为唯一逻辑所有者。

## Decision Outcome

采用方案 4。Mini Helper 升级为协议 v4，只返回原始事实，并用 `launchctl print system/com.apple.NetworkSharing` 替代 `ps | grep -q`。Helper 和 Guardian 分别报告共享进程及 `net.inet.ip.forwarding`，任何矛盾产生 `remoteEvidenceConflict`；forwarding 关闭产生 `sharingForwardingUnavailable`，禁止自动切回 Mini。

Guardian 的 ready 同时要求 `en0` 载波、预期地址/路由、正确共享拓扑、共享进程、forwarding 和 Mini 自身上游。MacBook 连续确认下游出口失败时，只能调用固定无参数 `report-egress-failure` 写入短期标记；Guardian 校验本地事实、标记时效和退避后，才可重拉一次原生 Network Sharing。所有恢复路径继续不调用 `-setdnsservers`。

MacBook 的降级 episode 从首次确认首选路径故障开始，与 Wi-Fi 回退是否成功无关。相同失败只记录一次；候选失败后等待网络事件或退避到期。Mini 自动切回必须看到新鲜、无冲突、forwarding=true 的远端事实以及连续 30 秒下游证明。

后续接管使用纯 `NetworkPolicyMachine.reduce(state:event:)` 和单 actor。每个 effect 携带 transaction ID、network generation、幂等键和 deadline。Route Safety Helper v2 把完整服务顺序写入 root-only 事务日志，切换后只能 commit、rollback 或进入 manual recovery。该接管先以只读影子模式运行 24 小时；与旧策略出现不安全分歧时保持旧执行路径并记录证据，不自动写路由。

## Consequences

- 正面：进程存在但 forwarding=0、Helper/Guardian 矛盾和下游 NAT 失败不再被“上游正常”掩盖。
- 正面：Wi-Fi 回退失败仍会进入 5 分钟降级时钟，并在退避期间停止重复命令和重复日志。
- 正面：下游报告本身不修改网络，Guardian 仍是 Mini 恢复的唯一所有者。
- 正面：状态机轨迹可重放，旧异步结果和并发切换可以用属性测试覆盖。
- 代价：Helper v4 与未来 Route Helper v2 都是 fail-closed 协议升级，需要各执行一次受限安装更新。
- 代价：纯状态机接管前需要 2 小时止血观察和 24 小时影子观察；旧策略至少保留一个版本作为紧急回退。
- 限制：`forwarding=1` 只是必要条件；最终可用性仍必须由 MacBook 下游和切换后系统/Clash HTTPS 证明。
- 限制：持续物理无载波和所有 Wi-Fi 候选不可用时，软件只能报告离线，不能制造连通性。

## Verification and Rollout

- Helper/Guardian 事实一致性由 [`sharing-facts-consistency`](../scripts/network-readiness-diagnostics.sh) 验证；完整 Mini 路径由 `mini-end-to-end-readiness` 验证。
- forwarding 与下游故障恢复由 [MiniGuardianRecoveryPlannerTests.swift](../Tests/NetBarTests/MiniGuardianRecoveryPlannerTests.swift) 覆盖；回退 episode 与副作用去重由 [NetworkRoutePolicyTests.swift](../Tests/NetBarTests/NetworkRoutePolicyTests.swift) 覆盖。
- 止血版本先安装并观察至少 2 小时。状态机随后以影子模式覆盖雷雳插拔、睡眠唤醒、Mini 上游故障、Wi-Fi 变化和 Clash TUN 在线；24 小时无不安全分歧后才接管。
- 接管后保留紧急回退一个版本；连续 7 天无不安全分歧后删除旧策略分支。
