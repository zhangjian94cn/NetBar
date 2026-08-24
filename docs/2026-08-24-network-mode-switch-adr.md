# ADR: NetBar 管理 Wi-Fi 与雷雳网桥物理出口优先级

- 日期: 2026-08-24
- 状态: accepted
- 范围: NetBar Direct Full / 本机网络服务控制
- 相关源码: [NetworkModeController.swift](../Sources/NetBar/Monitors/NetworkModeController.swift)、[NetworkModeCard.swift](../Sources/NetBar/Views/Components/NetworkModeCard.swift)
- 上位原则: [engineering-principles.md](../../../docs/engineering-principles.md)

## Context and Problem Statement

MacBook Pro 通过 IP over Thunderbolt 连接 Mac mini 后，系统同时存在 Wi-Fi、雷雳网桥、Clash TUN、aTrust、Tailscale 等网络路径。macOS 网络设置可能把雷雳网桥显示为“未知状态”，但二层链路、DHCP、Ping、SSH 和屏幕共享实际正常。用户需要在不关闭任何 VPN 的前提下，从 NetBar 明确查看链路真实状态，并在“本机 Wi-Fi 上网”和“经 Mac mini 上网”之间切换。

## Decision Drivers

- VPN 与代理连接不能被 NetBar 主动关闭、重启或改写。
- 切换必须保留所有现有网络服务及其启停状态。
- 状态结论必须来自实时服务顺序、雷雳载波、IP、网关、Peer 可达性和实际默认物理路由。
- 写入系统配置必须可验证、可自动恢复，并在恢复失败时明确暴露人工处理状态。
- App Store 沙盒版本不能获得此类系统写入能力。

## Considered Options

1. 创建两套 macOS 网络位置。该方案会复制或重建网络服务，第三方 VPN 服务在不同位置中的一致性难以保证，因此不采用。
2. 修改 Clash 全局脚本，让 Apple 连通性探测绕过 Fake-IP。该方案会把 NetBar 与第三方配置格式和订阅生命周期绑定，且不能证明物理路由真的切换，因此不采用。
3. 在当前网络位置中只交换 Wi-Fi 与雷雳网桥的服务优先级，并读取真实默认物理路由做验证。

## Decision Outcome

采用方案 3。NetBar 每次操作前读取完整服务顺序，通过硬件设备 `bridge0` 与 Wi-Fi 硬件端口识别目标服务，只交换两者的位置，其他服务原位保留。切换到 Mac mini 前要求雷雳链路、IPv4、网关和 Peer Ping 全部正常；写入后轮询验证服务顺序及默认物理路由，失败则恢复切换前顺序。

系统写入先以参数数组调用 `/usr/sbin/networksetup`；只有明确的授权失败才通过 AppleScript 的 `quoted form` 请求管理员授权。NetBar 不保存密码，也不执行任何 VPN 控制命令。功能只在 [DistributionFlavor.swift](../Sources/NetBar/App/DistributionFlavor.swift) 的 Direct Full 能力中开放。

## Consequences

- 正面：所有 VPN 服务保持原配置；切换范围小、可回读、可恢复；NetBar 状态不再依赖系统设置中的模糊黄点。
- 代价：服务优先级变化可能让既有连接短暂重收敛；权限策略严格的机器可能在切换时弹出管理员授权。
- 限制：NetBar 不保证 macOS 网络设置的状态点变绿，也不远程修改 Mac mini 的互联网共享配置。
- 恢复：验证失败自动恢复原顺序；恢复无法确认时，UI 进入“需要手动恢复”并打开系统网络设置，不宣称切换成功。

## Verification

- 解析、前置条件、权限回退、切换验证和恢复路径由 [NetworkModeControllerTests.swift](../Tests/NetBarTests/NetworkModeControllerTests.swift) 覆盖。
- 交付必须通过完整 `swift test`、Release 安装、二进制 SHA256 一致、LaunchAgent 单进程和无新增崩溃报告检查。
