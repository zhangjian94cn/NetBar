# ADR: Split Thunderbolt management and Internet Sharing address planes

- 日期: 2026-08-28
- 状态: accepted
- 范围: NetBar Direct Full / MacBook-Mac mini Thunderbolt management and shared egress
- 相关源码: [MacMiniLinkProfile.swift](../Sources/NetBar/Monitors/MacMiniLinkProfile.swift)、[NetworkLinkProvisioner.swift](../Sources/NetBar/Monitors/NetworkLinkProvisioner.swift)、[Mini Guardian](../Sources/NetBarMiniNetworkGuardian/main.swift)
- 上位原则: [engineering-principles.md](../../../docs/engineering-principles.md)
- 取代范围: [2026-08-25-thunderbolt-static-link-adr.md](2026-08-25-thunderbolt-static-link-adr.md) 中固定 `192.168.2.1/24`、`192.168.2.2/24` 与 Apple Internet Sharing 下游网段共存的假设

## Context and Problem Statement

实机同时出现 Mini `bridge0` 的 `192.168.2.1/24` 与 `192.168.3.1/24`、Apple DHCP 的 `192.168.2.x` 租约，以及 NetBar 固定 `192.168.2.1` 网关。点对点 Peer 仍可达，但 `com.apple.NetworkSharing` 反复退出、`ap1` inactive，MacBook 经 Mini 的 HTTPS 超时。原设计把稳定管理地址和 Apple 自主管理的 NAT/DHCP 地址放进同一 IPv4 网段，导致所有权重叠。

## Decision Drivers

- 固定管理链路必须在 Internet Sharing 停止时继续支持 SSH、VNC 与恢复。
- Apple Internet Sharing 继续唯一拥有下游 IPv4、DHCP、DNS proxy 和 NAT。
- 热点与 Thunderbolt 客户端必须同时使用同一 Apple 共享域。
- NetBar 不写私有 NAT 偏好，不关闭或改写 VPN/TUN，不保存热点密码。
- 迁移必须先建立新管理路径，再释放旧固定网段；失败可回滚且保持 Wi-Fi。

## Considered Options

1. 保留固定 `192.168.2.1/.2` 并继续重启共享。实机已证明会与 Apple 默认共享网段冲突。
2. NetBar 接管 PF、DHCP 和 DNS。权限、升级兼容和双 NAT 风险过高。
3. 仅保留热点或仅保留 Thunderbolt 出口。不能满足两者同时可用。
4. 固定管理别名使用独立 `/30`，数据面恢复 DHCP，由 Apple 动态分配共享网关。

## Decision Outcome

采用方案 4。Mini 与 MacBook 分别使用 `10.254.254.1/30`、`10.254.254.2/30` 作为 `bridge0` 的管理别名；Thunderbolt 网络服务使用 DHCP。SSH 连接目标改为管理别名，但 `HostKeyAlias` 保留 `192.168.2.1`，继续使用已登记的主机身份。

NetBar 从 DHCP 配置和实际路由发现共享 IPv4 与网关，不再把管理 Peer 当作默认网关。Guardian 维护管理别名并观察 Apple 共享；只有配置意图、服务、forwarding、上游与下游证据收敛后才允许 Mini 出口。系统共享总开关关闭时进入 `sharingManualPending`（运维语义 `manual_pending`），不写私有偏好。

共享总开关只通过 Apple 支持的“系统设置 → 通用 → 共享 → 互联网共享”路径配置，参见 [Apple Internet Sharing 使用说明](https://support.apple.com/guide/mac-help/share-internet-connection-mac-network-users-mchlp1540/mac)。服务恢复继续使用身份校验后的 `TERM` 和普通 `launchctl kickstart`，不使用 macOS 14.4 起受 SIP 限制的 `kickstart -k`，参见 [macOS 14.4 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos_14_4_release_notes)。

## Consequences

- 正面：管理链路不再与 Apple NAT/DHCP 争夺 `192.168.2.0/24`。
- 正面：热点与 Thunderbolt 客户端可以共享 Apple 选择的动态下游网段。
- 正面：Internet Sharing 故障不会切断 Mini 的 SSH/VNC 恢复路径。
- 代价：首次迁移需要两端管理员授权，并短暂中断热点。
- 代价：运行时必须区分管理别名、DHCP 地址和动态网关，旧 Helper 协议不兼容。
- 限制：macOS 共享总开关没有受支持的 NetBar 写接口；关闭时必须人工开启。

## Verification

- 单元测试覆盖多地址解析、协议 v5、`manualPending`、退避和迁移回滚。
- Direct Full 与 App Store Lite 分别验证 Helper 资源包含/排除契约。
- 实机验收要求管理 Peer、MacBook Thunderbolt DHCP/HTTPS、`zhuxiliuyun2` 客户端 HTTPS、Wi-Fi 回退和 VPN/TUN 前后不变量分别成立。
