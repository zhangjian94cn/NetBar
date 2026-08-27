# ADR: Mac mini 优先路由与双端自动自愈

- 日期: 2026-08-26
- 状态: partially superseded（共享 ready 与控制器所有权由 2026-08-27 ADR 取代）
- 范围: NetBar Direct Full / MacBook 路由策略与 Mac mini 上游恢复
- 相关源码: [NetworkRoutePolicy.swift](../Sources/NetBar/Monitors/NetworkRoutePolicy.swift)、[NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)、[Mini Guardian](../Sources/NetBarMiniNetworkGuardian/main.swift)、[Guardian 恢复规划器](../Sources/NetBarMiniNetworkGuardianSupport/RecoveryPlanner.swift)
- 被扩展决策: [2026-08-24-network-mode-switch-adr.md](2026-08-24-network-mode-switch-adr.md)、[2026-08-25-thunderbolt-static-link-adr.md](2026-08-25-thunderbolt-static-link-adr.md)
- 部分被取代: [2026-08-26-connectivity-first-candidate-failover-adr.md](2026-08-26-connectivity-first-candidate-failover-adr.md) 将固定双候选扩展为 Wi-Fi 白名单候选池，并将定时检查改为事件优先、定时兜底。
- 上位原则: [engineering-principles.md](../../../docs/engineering-principles.md)
- 取代决策: [2026-08-27-evidence-driven-network-policy-machine-adr.md](2026-08-27-evidence-driven-network-policy-machine-adr.md)

## Context and Problem Statement

Mac mini 内置以太网 `en0` 曾在 2026-08-25 10:59、11:16 和 17:47 出现物理载波丢失或抖动。macOS 会在载波消失后停止 `com.apple.NetworkSharing`；载波恢复后通常能重新应用 Manual IPv4 并启动共享，但原有 NetBar 只在弹出面板打开时检测，也不会在恢复后把 MacBook 切回首选的 Mini 出口。

固定雷雳地址已经保证两台 Mac 仍可互访。本决策需要让 Mini 在载波恢复后保守地监督系统收敛，并让 MacBook 在不改变 VPN、公司 DNS 或 Apple NAT 所有权的前提下自动回退和切回。

## Decision Drivers

- Mac mini 是首选物理出口；故障时连接优先，恢复稳定后自动返回首选出口。
- 无物理载波时软件不得循环禁用/启用 `en0`，避免放大交换机协商抖动。
- Mini 的 Manual IPv4 与公司 DNS 属于用户配置；DNS 必须保持逐项不变。
- 原生 `com.apple.NetworkSharing` 继续唯一管理 NAT、DHCP 和 DNS proxy。
- 自动切换必须有一次性、固定命令、可审计的最小 root 权限，不能后台弹管理员授权框。
- VPN/TUN 服务和进程不属于 NetBar 的控制范围。

## Considered Options

1. 继续只在弹窗打开时检测，由用户手动切换。无法满足无人值守回退和恢复后及时切回。
2. MacBook 远程负责 Mini 的全部恢复。MacBook 离线时 Mini 无法自愈，并扩大 SSH 控制面。
3. Mini Guardian 接管 NAT、DNS 或自动选择 `en8`/Wi-Fi。会与 Apple 私有共享配置争夺所有权，也可能覆盖公司网络策略。
4. Mini 使用事件驱动 Guardian 保守监督 `en0` 和原生共享；MacBook 使用独立策略协调器和受限 Helper 管理两项服务的相对顺序。

## Decision Outcome

采用方案 4。Mini Guardian 通过 `SCDynamicStore` 订阅 `en0` 和 IPv4 变化；无载波时只记录。载波恢复后先分别等待地址和共享各 15 秒，只有系统未收敛且 Setup 配置仍与 Profile 一致时才重新应用 IP/子网/路由器，且永不执行 `-setdnsservers`。共享仍未恢复时只重拉 `system/com.apple.NetworkSharing`，失败按 60 秒、5 分钟、15 分钟退避。

MacBook 持久化 `miniPreferred` 或 `localWiFi` 策略。Mini 不可用时自动回退；绑定 `bridge0` 的出口连续稳定 30 秒且 Mini Helper v3 报告 Guardian `ready` 后自动切回。两个固定探测目标中任一成功即可通过一轮，避免单个公网 ICMP 被公司网络屏蔽造成假阴性。10 分钟内发生两次自动回退时熔断 10 分钟。

本机 Route Safety Helper 只接受 `status`、`prefer-wifi`、`prefer-mini`、`rollback`；每次读取完整服务顺序，只交换 Wi-Fi 与 `bridge0` 的相对位置。Mini Helper v3 继续接受原三个固定命令，并只读聚合 Guardian 状态。两个 Helper 均通过精确 sudoers 授权，不接收服务名、命令或 Shell 片段。

## Consequences

- 正面：弹窗关闭时仍能回退；Mini 恢复并稳定后，MacBook 无需人工操作即可重新使用首选出口。
- 正面：物理链路、Mini 上游、共享服务和 MacBook 实际出口分别可观测，日志能够说明故障发生在哪一层。
- 正面：公司 DNS、其他 Mini 上游、VPN/TUN 和 Apple 私有 NAT 数据不在写入范围。
- 代价：Direct Full 需要在两台 Mac 上各完成一次受限组件安装授权，并新增一个 root LaunchDaemon。
- 代价：Guardian 依赖 macOS 的 `com.apple.NetworkSharing` 服务标签；系统升级后必须通过实机验收确认兼容性。
- 限制：持续无载波是物理网线、墙口或交换机端口问题，Guardian 只能等待并让 MacBook 保持 Wi-Fi。
- 恢复：本机切换失败会恢复完整原服务顺序；Mini 配置漂移时停止写入并报告，卸载 Guardian 不改变当前 IP、DNS 或 NAT 配置。

## Verification

- 策略、稳定窗口、熔断、Helper v3 和固定权限契约由 [NetworkRoutePolicyTests.swift](../Tests/NetBarTests/NetworkRoutePolicyTests.swift) 覆盖。
- Mini 的载波、配置漂移、地址/共享等待、修复动作、退避与健康重置由 [MiniGuardianRecoveryPlannerTests.swift](../Tests/NetBarTests/MiniGuardianRecoveryPlannerTests.swift) 覆盖。
- 固定链路、DNS 不变量、Guardian 操作边界和安装资源由 [NetworkStaticLinkTests.swift](../Tests/NetBarTests/NetworkStaticLinkTests.swift) 覆盖。
- 交付必须完成完整 `swift test`、Direct Full/App Store Lite 构建、sudoers/plist 校验、双机安装状态回读和 VPN 进程前后对比。
