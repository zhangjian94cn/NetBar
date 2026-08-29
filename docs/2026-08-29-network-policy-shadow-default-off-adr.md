# ADR: NetworkPolicyMachine 影子运行改为默认关闭

- 日期: 2026-08-29
- 状态: accepted
- 范围: NetBar Direct Full 网络出口状态机影子期
- 相关源码: [MonitorCoordinator.swift](../Sources/NetBar/App/MonitorCoordinator.swift)、[AppConfig.swift](../Sources/NetBar/App/AppConfig.swift)、[NetworkPolicyShadowCoordinator.swift](../Sources/NetBar/Monitors/NetworkPolicyShadowCoordinator.swift)
- 相关文档: [影子运行手册](2026-08-28-network-policy-shadow-rollout.md)、[证据驱动状态机 ADR](2026-08-27-evidence-driven-network-policy-machine-adr.md)

## Context and Problem Statement

`NetworkPolicyMachine` 与 `NetworkPolicyShadowCoordinator` 约 740 行源码、636 行测试，此前由 `MonitorCoordinator` 无条件构造，在每个 Direct Full 构建里随进程运行。它不持有任何执行器，所有 `NetworkPolicyEffect` 只落到 `~/Library/Logs/NetBar/network-events.jsonl` 成为 proposal。

接管门禁按运行手册仍是 `manual_pending`，且第 1 条明确规定：任何改变候选证明优先级、generation 或 reducer effect 的新构建都会重新开始 24 小时观察窗口，不能拼接旧构建的观察时长。这意味着在 UI 或其他领域高频迭代期间，影子采样产出的观察注定会被丢弃，却仍然持续消耗采样 CPU 与日志容量，并让两套领域模型（`NetworkRoutePolicyState` 与 `NetworkPolicyState`）长期并存于运行时。

## Decision Drivers

- 迁移资产必须保留：reducer、协调器与其测试仍要在 CI 里编译和运行。
- 观察窗口是一次有明确起止的活动，不是应用的常驻状态。
- 关闭路径必须零风险：不能因为开关引入新的分支行为。
- 不改变旧 `NetworkModeController` 作为唯一副作用所有者的地位。

## Considered Options

1. 维持现状，继续无条件影子运行。
2. 下沉到默认关闭的开关后面，需要观察时显式开启。
3. 本次直接完成接管，把 proposal 接到执行器。

## Decision Outcome

采用方案 2。新增 `AppConfig.networkPolicyShadowEnabled`（UserDefaults key `network_policy_shadow_enabled`，默认 `false`），并支持 `NETBAR_POLICY_SHADOW=1` 环境变量覆盖，便于一次性观察运行。`MonitorCoordinator` 在未开启时传 `policyShadow: nil`。

这条路径本身零风险：`NetworkModeController.policyShadow` 原本就是 `Optional` 且默认 `nil`，全部使用点都有 `guard`，关闭状态等价于该参数从未被传入。

方案 3 未被采用：接管需要重跑 24 小时窗口并逐条复核 proposal 分歧，与本次视觉/视图层改造混在同一批变更里会让两边都难以复核。

## Consequences

- 正面：常规迭代不再产生注定被丢弃的影子观察，也不再持续写入 shadow 日志。
- 正面：`NetworkPolicyMachine`、协调器与 636 行测试全部保留，接管资产不丢。
- 代价：真正开窗观察时需要记得显式开启；运行手册已相应更新。
- 后续：接管仍是消除 `NetworkRoutePolicyState` 与 `NetworkPolicyState` 双模型的根治方案，与 `NetworkModeController` 的拆分应作为同一个决策一起推进。
