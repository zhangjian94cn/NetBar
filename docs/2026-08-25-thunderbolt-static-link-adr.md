# ADR: 雷雳点对点链路使用双端固定地址与受限 Mini Helper

- 日期: 2026-08-25
- 状态: accepted（“不使用常驻 LaunchDaemon”与“恢复后不自动切回”部分已由 [2026-08-26-mac-mini-preferred-route-self-healing-adr.md](2026-08-26-mac-mini-preferred-route-self-healing-adr.md) supersede）
- 范围: NetBar Direct Full / MacBook 与 Mac mini 雷雳链路初始化
- 相关源码: [MacMiniLinkProfile.swift](../Sources/NetBar/Monitors/MacMiniLinkProfile.swift)、[NetworkLinkProvisioner.swift](../Sources/NetBar/Monitors/NetworkLinkProvisioner.swift)、[Mini Helper](../Sources/NetBar/Resources/MiniLinkHelper/netbar-mini-link-helper)、[安装器](../Sources/NetBar/Resources/MiniLinkHelper/install-netbar-mini-link-helper.command)
- 上位原则: [engineering-principles.md](../../../docs/engineering-principles.md)
- 扩展决策: [2026-08-24-network-mode-switch-adr.md](2026-08-24-network-mode-switch-adr.md)

## Context and Problem Statement

Mac mini 的原生 Internet Sharing 在上游 `en0` 失去载波时会停止 `InternetSharing/bootpd`，并撤销临时分配给 `bridge0` 的 `192.168.2.1`。MacBook 与 Mini 随后都可能退化到 `169.254/16`，从而使点对点访问与“经 Mac mini”模式同时失效。两端 `bridge0` 已聚合各自全部 Thunderbolt/USB4 接口，因此问题不在具体 Type-C 口，而在链路地址依赖 DHCP 与 Internet Sharing 生命周期。

## Decision Drivers

- 任意支持 Thunderbolt/USB4 的端口热插拔后，本地链路不依赖 DHCP 即可恢复。
- Mini 上游固定为内置以太网 `en0`；上游断开时保留 Mini 本地访问，但必须禁止经 Mini 上网。
- NetBar 不关闭、重启或改写 Clash、aTrust、Tailscale、Amnezia 及其他 VPN/TUN。
- 管理员授权边界必须固定、可审计，NetBar 不接收、传递或保存管理员密码。
- 初始化可重复执行，失败能够按已保存的真实原配置回滚。
- App Store Lite 产物不得携带 Helper 或远端写入能力。

## Considered Options

1. 继续依赖双端 DHCP 与原生 Internet Sharing。上游短暂掉线会再次撤销 Mini 地址，无法满足本地链路独立可用。
2. 增加常驻 LaunchDaemon，监控接口并自动重写地址或自动选择 Mini 上游。该方案扩大常驻权限、增加竞态，也违背上游固定 `en0` 的约束。
3. 修改私有 `com.apple.nat` 数据或由 Helper 自行管理 NAT/DHCP。私有格式不稳定，且会与 macOS Internet Sharing 争夺所有权。
4. 双端固定 `192.168.2.1/24` 与 `192.168.2.2/24`，保留原生 Internet Sharing 唯一管理 NAT/DHCP；需要时由非驻留受限 Helper 完成 Mini 端变更。

## Decision Outcome

采用方案 4。共享 [MacMiniLinkProfile.plist](../Sources/NetBar/Resources/MiniLinkHelper/MacMiniLinkProfile.plist) 定义地址、上游设备、SSH 身份和绑定出口探测目标。NetBar 把载波、固定地址、Peer 可达性与 Mini 上游状态分开；仅当 `/sbin/ping -b bridge0 -S 192.168.2.2` 的公网探测成功时，才允许“经 Mac mini”。

Mini Helper 安装于 `/Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper`，不是 LaunchDaemon。它只接受无自由参数的 `status`、`apply`、`rollback`，通过三个精确 sudoers 规则授权给 `zhangjian`。Helper 只识别设备为 `bridge0` 的网络服务，只读校验 Internet Sharing 的源为 `en0` 且目标包含 `bridge0`，不编辑 NAT 配置，也不操作 VPN 或其他接口。

初始化使用已有 `192.168.2.1` known_hosts 身份和 `HostKeyAlias`，严格拒绝未知或变化的密钥。两端在变更前保存 DHCP/Manual、IPv4、子网、路由器与 DNS；首次备份后重复初始化保持幂等。验证失败按相反顺序恢复本机和 Mini 的原配置，并恢复初始化前的完整服务顺序；任何恢复失败都进入“需要手动恢复”。

## Consequences

- 正面：雷雳本地访问不再跟随 Mini `en0` 和 DHCP 生命周期；更换两台 Mac 上的任意 Thunderbolt/USB4 端口无需重新租约。
- 正面：Mini 上游失败会被绑定接口探测识别，VPN/TUN 的公网可达性不会造成假阳性。
- 正面：Helper 权限固定、非驻留、无密码传递，且 App Store Lite 不打包这些资源。
- 代价：首次初始化需要用户分别在 Mini 和本机完成一次管理员授权；SSH 主机密钥或 Internet Sharing 拓扑不符合预期时会 fail closed。
- 代价：Mini `en0` 断开时不能经 Mini 上网；系统不会自动改用 USB 网卡或 Wi-Fi。
- 限制：普通仅充电或仅 USB 数据的 Type-C 线不在支持范围；系统设置中的黄色状态点仍不作为可信状态源。

## Verification

- 状态、绑定出口、SSH 身份、幂等备份与双端恢复由 [NetworkStaticLinkTests.swift](../Tests/NetBarTests/NetworkStaticLinkTests.swift) 覆盖。
- 服务顺序切换与自动恢复由 [NetworkModeControllerTests.swift](../Tests/NetBarTests/NetworkModeControllerTests.swift) 覆盖。
- Direct Full 必须包含资源 bundle；App Store Lite 构建必须断言 Helper 不在产物中。安装后还需核对二进制 SHA256、LaunchAgent 单进程、VPN 进程状态和运行日志。
