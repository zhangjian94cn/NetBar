# 2026-08-27 网络不稳定事件：证据校正

- 日期: 2026-08-28
- 范围: NetBar Direct Full / MacBook 到 Mac mini 的雷雳共享路径
- 相关源码: [NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)、[NetworkPolicyMachine.swift](../Sources/NetBar/Monitors/NetworkPolicyMachine.swift)、[Mini Guardian](../Sources/NetBarMiniNetworkGuardian/main.swift)

## 结论

2026-08-27 的现场记录正确识别了两类真实故障：原生 Internet Sharing 曾出现进程存在但转发未就绪，以及 MacBook 的 Clash TUN 数据面曾在底层出口变化后失去收敛。但两条临时结论不能作为长期判据：

1. 公网 ICMP 失败不是 macOS Internet Sharing 的固定行为。2026-08-28 对同一 `bridge0` 路径复测时，`1.1.1.1` 成功而 `114.114.114.114` 被丢弃；目标策略差异足以制造假阴性。
2. 关闭 TUN 是有效的系统代理模式，不是所有共享故障的唯一修复。TUN 开启时，只要持久配置、排除规则和 Mihomo 数据面一致，同一路径也可以通过绑定 HTTPS、系统 HTTPS 与显式代理验证。

## 决策修正

- 本地 Peer `192.168.2.1` 继续使用 Ping 验证固定链路。
- 公网 readiness 改为多目标、绑定物理接口的 HTTPS；公网 Ping 仅保留为诊断遥测。
- Internet Sharing 的本地事实与 MacBook 下游出口分别取证；进程 running 或 `forwarding=1` 都不能单独证明下游可用。
- Clash overlay 故障不能直接触发物理出口来回切换。物理路径与 overlay 分开判定，只有目标 underlay 失败且替代路径已验证时才切换。

## 现场日志反馈

旧控制器在一段故障轨迹中产生了数百次重复回退尝试。新的纯 reducer 使用 network generation 和事务相位丢弃晚返回结果，并保证同一未完成事务不会生成第二个路由写入；对应轨迹测试见 [NetworkPolicyMachineTests.swift](../Tests/NetBarTests/NetworkPolicyMachineTests.swift)。
