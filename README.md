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
| 🖼 应用图标 | 自动识别进程对应的 macOS 应用图标 |
| 🚀 开机自启 | 支持 Launch Agent 自动启动 |

## 📸 截图

菜单栏效果：紧凑的双行网速显示 + 网络图标

弹出面板：实时活跃应用排行 + 累计流量统计

## 🔧 安装

### 一键安装

```bash
git clone https://github.com/zhangjian94cn/NetBar.git
cd NetBar
chmod +x install.sh
./install.sh
```

安装脚本会自动：
1. 编译 Release 版本
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
└── Sources/NetBar/
    ├── NetBarApp.swift                   # @main 入口
    ├── AppDelegate.swift                 # 生命周期管理
    ├── NetworkMonitor.swift              # 总网速监控 (sysctl)
    ├── ProcessTrafficMonitor.swift       # 按应用流量 (nettop)
    ├── ProxyDetector.swift               # 系统代理检测
    ├── TrafficStore.swift                # 持久化流量存储
    ├── AppIconResolver.swift             # 应用图标解析
    ├── NetworkInfoProvider.swift         # Wi-Fi/IP 信息
    ├── StatusBarController.swift         # 菜单栏控制 + 自定义绘制
    └── Views/MenuPopoverView.swift       # 弹出面板 UI
```

## 🏗 技术实现

- **网速监控**：通过 `sysctl` + `NET_RT_IFLIST2` 读取 64 位网络接口计数器
- **进程流量**：解析 `nettop` 命令输出，按进程聚合
- **代理检测**：分析每个连接的网络接口（`en0` = 直连，`utun*` = VPN/代理）
- **持久化**：JSON 文件按天存储，每小时汇总，存放在 `~/Library/Application Support/NetBar/`
- **菜单栏渲染**：自定义 `NSView` 子类，CoreGraphics 逐像素绘制，确保像素级完美对齐
- **应用图标**：`NSRunningApplication` + `mdfind` 双策略查找，带内存缓存

## 📋 系统要求

- macOS 13.0 (Ventura) 或更高版本
- Swift 5.9+

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

## 📄 许可证

[MIT License](LICENSE)
