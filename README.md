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

首次使用链路自动切换时，还需在卡片中分别安装本机 Route Safety Helper 和 Mini 自愈组件；两个安装器各请求一次系统管理员授权，不保存密码。

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

Direct Full 版本会在弹出面板中显示“Mac mini 链路”卡片：

- **固定 Wi-Fi**：持久使用 Wi-Fi 作为物理出口，雷雳仍可访问 Mac mini，并关闭自动切回。
- **自动（Mini 优先）**：Mini 健康时使用 Mini；雷雳断开、固定地址丢失或 Peer 不可达时立即回退到已验证 Wi-Fi，不离线等待。绑定 `bridge0` 的出口连续稳定 30 秒且 Mini Guardian 报告正常后自动切回。
- **立即用 Wi-Fi**：只临时保网，不改变“Mini 优先”的长期策略。
- **Wi-Fi 候选**：只自动尝试“附近可见、macOS 已保存、用户手动置顶”三者的交集；当前健康候选会保留，不为了排名主动换网。NetBar 不读取钥匙串或 Wi-Fi 密码。
- **初始化/修复链路**：把 Mac mini 固定为 `192.168.2.1/24`、本机固定为 `192.168.2.2/24`。两端 `bridge0` 包含全部雷雳口，因此换到任意 Thunderbolt/USB4 口后不再依赖 DHCP。

第一次展开候选池时，macOS 可能询问定位权限，这是 CoreWLAN 扫描附近 SSID 所需。拒绝后 NetBar 不会盲连其他不可见 SSID；若 macOS 连当前 SSID 名称也隐藏，但 `en0` 已经关联并取得 IPv4/网关，NetBar 仍可把这条现有连接作为匿名临时候选保网，不执行 SSID 关联，也不把它加入持久白名单。需要密码、网页登录或管理员关联的网络只显示原因并跳过，后台不会弹授权框。

回退后的前 5 分钟是 Mini 积极恢复窗口：Wi-Fi 已经保网，同时每 10 秒检查 Mini。满 5 分钟仍不可用会进入稳定 Wi-Fi 降级，Mini 检查降为每 60 秒一次；这 5 分钟不是断网等待时间。10 分钟内重复自动切回再失败会熔断 10 分钟，避免两个出口反复抖动。

首次初始化需要在 Mac mini 终端和本机各完成一次管理员授权。Mini Helper v3 仅允许 `status`、`apply`、`rollback` 三个固定命令；本机 Route Safety Helper 仅允许 `status`、`prefer-wifi`、`prefer-mini`、`rollback`。NetBar 不接收或保存管理员密码。SSH 连接严格复用 `192.168.2.1` 已登记的主机密钥，不自动接受未知或变化的密钥。

Mac mini 的上游固定为内置以太网 `en0`。`en0` 断开时，雷雳本地链路和 `192.168.2.1` 访问仍保持可用，MacBook 自动回退 Wi-Fi。Mini Guardian 不会重置无载波的网口；载波恢复后先等待 macOS 自行收敛，必要时只重新应用既定 Manual IPv4 和重拉 `com.apple.NetworkSharing`。它不调用 `-setdnsservers`，因此用户为公司网络配置的 DNS 保持不变。NetBar 不自动改用 Mini 的 USB 网卡或 Wi-Fi，原生 Internet Sharing 继续唯一管理 NAT/DHCP。

状态语义：红色表示雷雳本地链路不可用；黄色表示 Mini 无载波、地址/共享恢复中、配置漂移、退避、出口抖动或 Clash/TUN 未收敛；绿色只表示固定链路、Mini Guardian 与绑定物理出口均已验证。明确链路故障立即回退；只有公网 HTTPS 不确定故障才需要三轮失败。Apple 与 Cloudflare 目标中至少一个返回预期状态即可通过，避免单目标被公司网络屏蔽导致误判。

Wi-Fi 先验证载波、IPv4 和网关；能绑定 `en0` 直连 HTTPS 时采用 make-before-break。部分公司网络会阻断绕过代理的 HTTPS，这时 NetBar 允许短暂提升 Wi-Fi 后，以“实际物理出口为 `en0` 且系统 HTTPS、Clash HTTPS 均成功”确认保网，失败则如实告警。若直连正常但 Clash/System TUN 仍失败，NetBar 最多调用一次 Mihomo `DELETE /connections` 关闭旧连接，让新连接跟随新底层路由；它不退出、重启、重载 Clash，不切换 TUN，也不修改 Clash 配置。60 秒冷却内不会重复清理。

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

该功能不关闭或重启 Clash、aTrust、Tailscale、Amnezia 等 VPN，也不修改 Clash 配置。Clash 持久配置（包括 IPv6）继续由 `dual-vpn-config` 独占治理。VPN 开启时公网 IP 仍可能显示 VPN 出口；卡片展示的是 VPN 下层的物理出口。系统设置即使仍显示黄色“未知状态”，也不影响 NetBar 根据载波、IP、网关、绑定 HTTPS 和默认路由给出的实测结果。

App Store Lite 受沙盒限制，不包含网络模式切换、SSH 写入、初始化按钮或 Mini Helper 资源。

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
