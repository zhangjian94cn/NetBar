# NetBar — macOS 菜单栏网速监控

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" />
  <img src="https://img.shields.io/badge/swift-5.9-orange" />
  <img src="https://img.shields.io/badge/license-MIT-green" />
</p>

一款轻量级 macOS 菜单栏网速监控工具，实时显示上传/下载速度，按应用统计流量，检测代理/VPN 状态。

## ✨ 功能特性

| 功能 | 说明 |
|------|------|
| 📊 实时网速 | 菜单栏常驻显示上传/下载速度 |
| 📱 按应用统计 | 查看每个应用的实时带宽消耗 |
| 🔒 代理检测 | 自动识别每个应用是直连/代理/混合 |
| 💾 持久化存储 | 流量数据写入磁盘，支持长期统计 |
| 📅 多时间维度 | 1分钟 / 5分钟 / 1小时 / 今天 / 7天 / 30天 / 本月 |
| 🌐 网络信息 | Wi-Fi 名称 + 本机 IP 地址 |
| ⚡ Mac mini 链路 | 固定双端 IP、Wi-Fi 候选保网、Mini 上游自愈、故障自动回退及稳定 30 秒后自动切回（Direct Full） |
| 🧭 双控制 Tab | `网络出口` 管物理路径，`Clash 模式` 由用户手动选择系统代理或 TUN 全局（Direct Full） |
| 🖼 应用图标 | 自动识别进程对应的 macOS 应用图标 |
| 🚀 开机自启 | 支持 Launch Agent 自动启动 |

## 📸 截图

### 菜单栏

![菜单栏效果](screenshots/menubar.png)

## 🔧 安装

### 一键安装

```bash
git clone https://github.com/zhangjian94cn/NetBar.git
cd NetBar
chmod +x install.sh
./install.sh
```

安装脚本会自动：
1. 编译 Direct Full Release 版本
2. 打包为 `NetBar.app` 并安装到 `~/Applications/`
3. 配置 Launch Agent 实现开机自启

首次使用链路自动切换时，还需在卡片中分别安装本机 Route Safety Helper 和 Mini 自愈组件；两个安装器各请求一次系统管理员授权，不保存密码。Route Safety Helper v3 安装后，普通出口切换和符合条件的 Wi-Fi 自动 DNS 修复均使用精确 sudoers 命令，不再重复弹出授权框。

### 手动编译

```bash
swift build -c release
```

## 📁 项目结构

```
NetBar/
├── Package.swift                         # SPM 包描述
├── Info.plist                            # macOS App Bundle 配置
├── install.sh                            # 一键安装脚本
├── com.netbar.agent.plist                # Launch Agent 配置
├── Resources/
│   └── AppIcon.icns                      # 应用图标
└── Sources/NetBar/
    ├── App/                              # 应用入口 & 基础设施
    │   ├── NetBarApp.swift               # @main 入口
    │   ├── AppDelegate.swift             # 生命周期管理
    │   ├── MonitorCoordinator.swift      # 服务编排器
    │   ├── MonitorProtocol.swift         # 统一生命周期协议
    │   └── StatusBarController.swift     # 菜单栏控制 + 浮层面板管理
    ├── Monitors/                         # 核心监控服务
    │   ├── NetworkMonitor.swift          # 总网速 (sysctl)
    │   ├── NetworkModeController.swift   # 候选编排、Wi-Fi / 雷雳物理出口检测、切换与回滚
    │   ├── ClashOverlayModeController.swift # 用户触发的系统代理 / TUN 事务
    │   ├── NetworkConnectivity.swift     # CoreWLAN 候选、分层 HTTPS 探测、事件与隐私日志
    │   ├── ProcessTrafficMonitor.swift   # 按应用流量（聚合 nettop + mihomo）
    │   ├── NettopParser.swift            # nettop 命令执行与解析
    │   ├── MihomoClient.swift            # Mihomo 代理 API 客户端
    │   ├── ProxyDetector.swift           # 系统代理/VPN 检测
    │   ├── VPSTrafficMonitor.swift       # VPS 流量 (3X-UI API)
    │   └── NetworkInfoProvider.swift     # Wi-Fi/IP 信息
    ├── Storage/
    │   └── TrafficStore.swift            # 持久化流量存储
    ├── Utilities/
    │   ├── Formatters.swift              # 格式化工具
    │   ├── AppIconResolver.swift         # 应用图标解析
    │   └── InsecureURLSession.swift      # 忽略自签证书的 URLSession
    └── Views/                            # SwiftUI UI 层
        ├── MenuPopoverView.swift         # 弹出面板主视图
        └── Components/                   # 可复用 UI 组件
            ├── AppSpeedRow.swift
            ├── NetworkControlTabs.swift
            ├── CumulativeRow.swift
            ├── ProxyBadge.swift
            ├── StatusBarView.swift
            ├── TimePeriodPopUpButton.swift
            ├── TrafficTableRow.swift
            └── VPSTrafficCard.swift
```

## 🏗 技术实现

- **网速监控**：通过 `sysctl` + `NET_RT_IFLIST2` 读取 64 位网络接口计数器
- **进程流量**：解析 `nettop` 命令输出，按进程聚合
- **代理检测**：分析每个连接的网络接口（`en0` = 直连，`utun*` = VPN/代理）
- **雷雳模式切换**：读取完整网络服务顺序、`bridge0` 链路、Mac mini 网关及默认物理路由；只交换 Wi-Fi 与雷雳服务，失败自动恢复
- **持久化**：JSON 文件按天存储，每小时汇总，存放在 `~/Library/Application Support/NetBar/`
- **菜单栏渲染**：自定义 `NSView` 子类，CoreGraphics 逐像素绘制，确保像素级完美对齐
- **应用图标**：`NSRunningApplication` + `mdfind` 双策略查找，带内存缓存

## 📋 系统要求

- macOS 13.0 (Ventura) 或更高版本
- Swift 5.9+

## ⚡ Mac mini 雷雳链路

Direct Full 版本把网络控制拆成两个 Tab。顶部总览固定显示在线状态、已验证物理出口、当前 Clash 模式和主要故障层；`网络出口` Tab 提供：

- **Mac mini 优先**：Mini 健康时使用 Mini；雷雳断开、固定地址丢失或 Peer 不可达时立即回退到已验证 Wi-Fi，不离线等待。绑定 `bridge0` 的出口连续稳定 30 秒且 Mini Guardian 报告正常后自动切回。
- **Wi-Fi 优先**：持久把 Wi-Fi 排在雷雳网桥之前；雷雳仍可访问 Mac mini，但 NetBar 不主动切回 Mini。
- **Wi-Fi 候选**：只自动尝试“附近可见、macOS 已保存、用户手动置顶”三者的交集；当前健康候选会保留，不为了排名主动换网。NetBar 不读取钥匙串或 Wi-Fi 密码。
- **初始化/修复链路**：在 Mac mini 与本机的 `bridge0` 上分别保留 `10.254.254.1/30`、`10.254.254.2/30` 管理别名；雷雳网络服务本身使用 DHCP，数据地址、网关、DNS proxy 与 NAT 由 Apple Internet Sharing 动态管理。

第一次展开候选池时，macOS 可能询问定位权限，这是 CoreWLAN 扫描附近 SSID 所需。拒绝后 NetBar 不会盲连其他不可见 SSID；若 macOS 连当前 SSID 名称也隐藏，但 `en0` 已经关联并取得 IPv4，候选池会显示“当前已连接 Wi-Fi”，并可直接用于保网。该匿名候选不执行 SSID 关联，也不写入持久白名单。需要密码、网页登录或管理员关联的网络只显示原因并跳过，后台不会弹授权框。

回退后的前 5 分钟是 Mini 积极恢复窗口：Wi-Fi 已经保网，同时每 10 秒检查 Mini。满 5 分钟仍不可用会进入稳定 Wi-Fi 降级，Mini 检查降为每 60 秒一次；这 5 分钟不是断网等待时间。10 分钟内重复自动切回再失败会熔断 10 分钟，避免两个出口反复抖动。

首次初始化需要在 Mac mini 终端和本机各完成一次管理员授权。Mini Helper v5 仅允许 `status`、`prepare`、`migrate`、`rollback`、`finalize-rollback`、`report-egress-failure` 六个固定无参数命令；迁移先建立并验证管理地址 SSH，再切换 DHCP，回滚先恢复并验证旧链路，最后移除管理别名。本机 Route Safety Helper v4 仅允许固定无参数命令，并持续补回管理别名。NetBar 不接收或保存管理员密码。SSH 连接目标改为 `10.254.254.1` 后仍严格复用 `192.168.2.1` 的 `HostKeyAlias`，不自动接受未知或变化的密钥。

Mac mini 的唯一上游是内置以太网 `en0`。`en0` 或 Internet Sharing 断开时，`10.254.254.1/.2` 管理链路仍用于 SSH、VNC、健康检查和恢复，MacBook 自动回退 Wi-Fi。Mini Guardian 不重写 `en0`、公司 DNS、NAT 或 DHCP；它只维护管理别名、观察 Apple 数据面，并在共享意图仍开启时受限重启原生服务。共享总开关关闭时状态为 `manual_pending`，必须在“系统设置 → 通用 → 共享 → 互联网共享”中人工开启。

Guardian 的 `ready` 现在必须同时满足 `en0` 载波、预期地址与路由、共享拓扑、Network Sharing 进程、`net.inet.ip.forwarding=1` 和 Mini 自身上游探测。Helper 与 Guardian 对同一事实不一致时显示“共享状态证据冲突”；进程 running 但 forwarding=0 时显示“Mac mini 上游正常 · 共享转发未就绪”，期间保持 Wi-Fi。较新的 macOS/SIP 不允许对该关键系统服务执行 `launchctl kickstart -k`，因此 Guardian 会严格验证 `/usr/libexec/InternetSharing` 的进程身份，终止旧实例并等待其完全退出，再使用不带 `-k` 的启动请求让 launchd 重建原生服务；它不直接强写 forwarding。若公司 VPN 随即再次关闭 forwarding，Guardian 进入退避并继续保持 Wi-Fi，不与 VPN 循环争夺。`forwarding=1` 只是必要条件，绿色仍要求 MacBook 下游和切换后系统/Clash 数据面共同验证。

恢复退避只限制下一次写操作，Guardian 在 60 秒、5 分钟或 15 分钟退避期间仍每 15 秒刷新进程、forwarding、载波、地址和路由事实。这样公司 VPN 退出或系统自行恢复时可以及时重新进入 30 秒稳定验证，而不会等到写操作退避结束；重复失败原因在只读采样中保持，不被空状态覆盖。

状态分别展示固定管理链路、雷雳共享出口、热点 AP 与客户端证据。绿色出口要求管理 Peer、Apple DHCP 地址/动态网关、实际物理默认路由和绑定 `bridge0` 的 HTTPS 连续稳定 30 秒；旧租约、进程 running 或 `forwarding=1` 都不能单独判定就绪。未观测到真实热点客户端时只显示“热点已配置，客户端出口未验证”。

Wi-Fi 先验证载波、IPv4 和网关；能绑定实际 Wi-Fi 设备直连 HTTPS 时采用 make-before-break。部分公司网络会阻断绕过代理的 HTTPS，因此公网 ICMP 和单次直连失败都不是 readiness 的决定性证据。Mini 切换前组合固定 Peer、Guardian、forwarding 与绑定 `bridge0` 的 TCP/TLS 事实，切换后再以实际物理路由、系统 HTTPS 和 Clash HTTPS 确认可用。每当实际物理出口在 `bridge0` 与 Wi-Fi 之间变化，NetBar 都会通过 Mihomo Unix Socket 调用一次 `DELETE /connections`，关闭旧 underlay 上的运行中连接，再等待并验证新连接；同一出口的重复检查不会重复清理。网络出口状态机不退出、重启、重载 Clash，也不会开关 TUN。

DNS 是端到端互联网证明的一部分，但不是固定雷雳管理链路的成立条件。若雷雳断开而 Wi-Fi 的手动 DNS 仍包含旧 Mini 地址 `192.168.2.1`，NetBar 会先把物理出口保留在 Wi-Fi，并显示“受限在线 · DNS 仍依赖 Mac mini”；它不会回滚到断开的 Mini，也不会在插拔时静默改写 DNS。用户可点击一次“恢复 Wi-Fi 自动 DNS”，Route Safety Helper v4 会备份原值、设置自动 DNS、等待 scoped resolver 和数据面收敛，成功提交，失败完整回滚。`114.114.114.114`、公司 DNS及其他手动 DNS只诊断，不自动修改。

“应用诊断”分别显示系统 HTTPS、显式 Clash、代理不感知/TUN 和 ZCode 后台链路。ZCode 请求不包含 token、Cookie 或账号信息，匿名响应 2xx–4xx 即表示传输可达；ZCode 服务本身的故障不会触发 Mac mini/Wi-Fi 切换。

### Clash 模式

`Clash 模式` Tab 只接受用户点击，网络插拔和自动故障转移不会改变选择：

- **系统代理**：关闭 TUN，保持 Clash 进程与指向当前 mixed-port 的系统代理在线；适合优先稳定性。
- **TUN 全局**：开启 TUN；启用前必须验证 `ipv6=false` 以及 aTrust、LAN、Tailscale、WireGuard 排除基线。

Direct Full 新安装推荐 `TUN 全局`，以覆盖不遵循系统代理的 ZCode/CLI 后台程序；已有安装保留用户当前选择，网络插拔和自动故障转移绝不静默迁移模式。

切换是用户级事务，不需要管理员密码：NetBar 备份 `verge.yaml` 并校验 SHA-256，只修改唯一顶层 `enable_tun_mode`，再通过 Mihomo Unix Socket 更新 runtime。持久值、runtime、系统代理、显式代理 HTTPS 或系统 HTTPS 任一验证失败都会恢复文件和原 runtime，不会重启 Clash。除这个标量外，所有 Clash 共存字段继续由 `dual-vpn-config` 独占治理。

查看 MacBook 侧状态转换：

```bash
log show --last 1h --style compact --predicate 'subsystem == "com.zjah.NetBar" AND category == "network"'
tail -n 100 ~/Library/Logs/NetBar/network-events.jsonl
```

JSONL 只记录状态转换和修复动作，候选以 SHA-256 短标识保存，不写 SSID、BSSID、密码或代理凭据；日志上限 2 MB，并清理 7 天前的记录。

查看 Mini Guardian 状态与日志：

```bash
sudo -n /Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper status
log show --last 1h --style compact --predicate 'subsystem == "com.zjah.NetBarMiniNetworkGuardian"'
```

仓库提供三个只读诊断入口：

```bash
./scripts/network-readiness-diagnostics.sh sharing-facts-consistency
./scripts/network-readiness-diagnostics.sh mini-end-to-end-readiness
./scripts/network-readiness-diagnostics.sh network-trace-replay
```

它们分别验证远端 Helper/Guardian/`launchctl`/`sysctl` 一致性、完整 Mini 下游路径，以及脱敏故障轨迹能否收敛而不重复报告或刷回退日志。

Direct Full 当前同时运行只读 `NetworkPolicyMachine` 影子协调器。SCDynamicStore 与 CoreWLAN 的连续事件先合并 250 ms，再形成一个 generation；Mini Guardian 等远端证据发生实质变化也会形成新 generation。影子协调器只把 `network_policy_shadow_observation`、`network_policy_shadow_generation` 和 `network_policy_shadow_proposal` 写入上述 JSONL，不执行 proposal。必须完成覆盖插拔、睡眠、Mini VPN、Wi-Fi 变化和两种 Clash 模式的 24 小时审阅后，才允许它接管真实路由。

自动网络策略不关闭或重启 Clash、aTrust、Tailscale、Amnezia 等 VPN，也不修改 Clash 模式。只有用户在 `Clash 模式` Tab 点击时才执行上述窄事务。VPN 开启时公网 IP 仍可能显示 VPN 出口；卡片展示的是 VPN 下层的物理出口。系统设置即使仍显示黄色“未知状态”，也不影响 NetBar 根据载波、IP、网关、绑定 TCP/TLS 和默认路由给出的实测结果。

App Store Lite 受沙盒限制，不包含网络模式切换、SSH 写入、初始化按钮、Mini Helper 或 Clash 模式写入能力。

Direct Full 构建产物：

```bash
./scripts/build-direct.sh
```

App Store Lite 构建会额外验证产物不包含 Helper：

```bash
./scripts/build-appstore.sh
```

## 🗑 卸载

```bash
# 停止并卸载
pkill NetBar
launchctl unload ~/Library/LaunchAgents/com.netbar.agent.plist
rm ~/Library/LaunchAgents/com.netbar.agent.plist
rm -rf ~/Applications/NetBar.app

# 清除数据
rm -rf ~/Library/Application\ Support/NetBar/
```

如果安装过本机 Route Safety Helper，再删除：

```bash
sudo rm -f /etc/sudoers.d/netbar-route-safety-helper
sudo rm -f /Library/PrivilegedHelperTools/com.zjah.NetBarRouteSafetyHelper
sudo rm -rf /Library/Application\ Support/NetBar/RouteSafety
```

如果安装过 Mini Helper/Guardian，请先在 Mac mini 上恢复初始化前的雷雳配置，再删除受限组件。以下命令不会修改 `en0` 的 IP 或公司 DNS：

```bash
sudo -n /Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper rollback
sudo launchctl bootout system/com.zjah.NetBarMiniNetworkGuardian
sudo rm -f /Library/LaunchDaemons/com.zjah.NetBarMiniNetworkGuardian.plist
sudo rm -f /etc/sudoers.d/netbar-mini-link-helper /etc/sudoers.d/com.zjah.NetBarMiniLinkHelper
sudo rm -f /Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper
sudo rm -f /Library/PrivilegedHelperTools/com.zjah.NetBarMiniNetworkGuardian
sudo rm -rf /Library/Application\ Support/NetBar
```

## 📄 许可证

[MIT License](LICENSE)
