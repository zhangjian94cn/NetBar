# NetBar 地址面拆分迁移日志

- 日期: 2026-08-28
- 原始分支: `codex/netbar-sharing-address-plane-split`
- 集成分支: `codex/netbar-address-plane-dns-integration`
- 原始基线: `origin/main` at `24246ec9de78358ea77f1e25f7e9116bde0decca`
- 决策: [地址面拆分 ADR](2026-08-28-split-management-and-sharing-address-planes-adr.md)
- 实现: [NetworkLinkProvisioner.swift](../Sources/NetBar/Monitors/NetworkLinkProvisioner.swift)、[Mini Helper](../Sources/NetBar/Resources/MiniLinkHelper/netbar-mini-link-helper)、[Mini Guardian](../Sources/NetBarMiniNetworkGuardian/main.swift)

## 构建与契约验证

- `swift test`: 194 tests, 0 failures。
- `swift build -c release`: 通过。
- Direct Full: `dist/direct/NetBar-direct-full.zip`，SHA-256 `fa43494262be90a8a5156d3d93086cfa0b525b4fa4989f7b812755689d4dea57`。
- App Store Lite: Helper、Guardian 与 SSH 能力排除检查通过；二进制 SHA-256 `84fe5b72d36e024b3674b8d440ac879e6c40b81f7cb46773f6769906517ef1dc`。
- Mini Helper、Route Safety Helper 通过 `zsh -n`，plist 通过 `plutil -lint`，sudoers 通过 `visudo -cf`，`git diff --check` 通过。

## 迁移前现场快照

- 原工作区与运行中 App 未被候选构建覆盖；运行中 App/原工作区 Release 哈希一致。
- MacBook 原雷雳服务为固定 `192.168.2.2/24`，Mini Peer 为 `192.168.2.1`；Mini Helper 为 v4。
- 发现并收敛一笔旧 Route Safety 悬空事务；随后以受限 Helper 切到 Wi-Fi，系统 HTTPS 验证成功并提交，事务状态为空。
- aTrust、Clash/Mihomo 与 Tailscale 进程均保持运行；未修改其配置或模式。
- 两机 v5 安装前均不具备通用免密 sudo，符合“一机一次管理员授权”预期。

## 2026-08-28 集成状态

- 用户已完成 Mini 端一次管理员授权；Mini Helper v5 与 Guardian 已安装，协议及文件身份回读成功。
- Mini 当前仍保留旧的 `192.168.2.1` 固定配置，因此 v5 正确返回 `configurationDrift`，没有擅自迁移或宣称 ready。
- MacBook Route Safety Helper 仍为 v3，当前保持 Wi-Fi 且无 pending transaction；必须升级到 v4 并由集成后的 provisioner 事务性完成两端迁移。
- DNS/Application facts、只读影子状态机、当前健康路径保护，以及“只有实际 Mini 出口才能上报下游失败”的反馈环修复均已与 v5 合并；完整测试为 205 项通过。
- 当前 Wi-Fi、Clash TUN 与 ZCode 匿名传输路径健康；迁移完成前不把 Mini 提升为物理出口。

## 剩余迁移步骤

1. 回读 Mini Helper v5 与 Guardian 状态。
2. 预检两机 `10.254.254.0/30` 地址和路由冲突。
3. `prepare` 两端管理别名，使用 `HostKeyAlias=192.168.2.1` 验证新管理地址 SSH。
4. Mini `migrate` 后本机迁回 DHCP；保留 Wi-Fi 优先。
5. 若共享总开关关闭，打开系统设置并停在人工确认门禁。
6. 验证管理 Peer、动态 DHCP/网关、绑定 HTTPS、热点 AP 与客户端证据；失败按 v5 顺序回滚。
