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
| ⚡ Mac mini 链路 | 固定双端 IP、检测并修复 IP over Thunderbolt，切换本机 Wi-Fi / Mac mini 物理出口（Direct Full） |
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
    │   ├── NetworkModeController.swift   # Wi-Fi / 雷雳物理出口检测、切换与回滚
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

- **本机 Wi-Fi**：Wi-Fi 是物理上网出口，雷雳仍可访问 Mac mini。
- **经 Mac mini**：雷雳网桥是物理上网出口；切换前必须确认 Mac mini 网关可达，并且绑定 `bridge0` 的公网探测成功。
- **初始化/修复链路**：把 Mac mini 固定为 `192.168.2.1/24`、本机固定为 `192.168.2.2/24`。两端 `bridge0` 包含全部雷雳口，因此换到任意 Thunderbolt/USB4 口后不再依赖 DHCP。

首次初始化需要在 Mac mini 终端和本机各完成一次管理员授权。Mini 端安装的是非驻留受限 Helper，仅允许 `status`、`apply`、`rollback` 三个固定命令；NetBar 不接收或保存管理员密码。SSH 连接严格复用 `192.168.2.1` 已登记的主机密钥，不自动接受未知或变化的密钥。

Mac mini 的上游固定为内置以太网 `en0`。`en0` 断开时，雷雳本地链路和 `192.168.2.1` 访问仍保持可用，但“经 Mac mini”会被禁用；NetBar 不自动改用 Mini 的 USB 网卡或 Wi-Fi。原生 macOS Internet Sharing 继续唯一管理 NAT/DHCP，Helper 只读校验其共享源和目标，不修改私有 NAT 配置。

该功能不关闭或重启 Clash、aTrust、Tailscale、Amnezia 等 VPN，也不修改 Clash 配置。VPN 开启时公网 IP 仍可能显示 VPN 出口；卡片展示的是 VPN 下层的物理出口。系统设置即使仍显示黄色“未知状态”，也不影响 NetBar 根据载波、IP、网关、Ping 和默认路由给出的实测结果。

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

如果安装过 Mini Helper，请先在 Mac mini 上恢复初始化前配置，再删除权限文件和 Helper：

```bash
sudo -n /Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper rollback
sudo rm /etc/sudoers.d/com.zjah.NetBarMiniLinkHelper
sudo rm /Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper
sudo rm -rf /Library/Application\ Support/NetBar
```

## 📄 许可证

[MIT License](LICENSE)
