#!/bin/bash
# NetBar 安装脚本 — 编译、打包为 .app、配置开机自启

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/NetBar.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
PLIST_NAME="com.netbar.agent.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "🔨 编译 Release 版本..."
cd "$SCRIPT_DIR"
swift build -c release -Xswiftc -DDIRECT_FULL

echo "📦 打包 NetBar.app 到 $HOME/Applications ..."
# 先杀死正在运行的 NetBar，确保新编译的二进制能正确被打包并替换
pkill NetBar || true
# 清理旧的应用
rm -rf "$APP_DIR"
# 创建目录结构
mkdir -p "$BIN_DIR"
mkdir -p "$RES_DIR"

# 复制二进制和 Info.plist
cp .build/release/NetBar "$BIN_DIR/"
cp -R .build/release/NetBar_NetBar.bundle "$RES_DIR/NetBar_NetBar.bundle"
cp .build/release/NetBarMiniNetworkGuardian "$RES_DIR/NetBar_NetBar.bundle/MiniLinkHelper/NetBarMiniNetworkGuardian"
chmod 0755 "$RES_DIR/NetBar_NetBar.bundle/MiniLinkHelper/NetBarMiniNetworkGuardian"
if [ -f "Info.plist" ]; then
    cp Info.plist "$APP_DIR/Contents/"
else
    echo "警告: 未找到 Info.plist"
fi

if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$RES_DIR/"
else
    echo "警告: 未找到 Resources/AppIcon.icns"
fi

echo "🔑 VPS 配置入口已改为应用内设置 > 服务器管理。"
echo "🛡️  自动路由组件可在 NetBar 链路卡片中完成一次授权安装。"

echo "⚙️  配置开机自启..."
# 先卸载旧的（如果存在）
launchctl unload "$PLIST_DST" 2>/dev/null || true
cp "$PLIST_SRC" "$PLIST_DST"
launchctl load "$PLIST_DST"

echo ""
echo "✅ NetBar 已安装并打包为标准 macOS 应用！"
echo "   应用位置: $APP_DIR"
echo "   LaunchAgent: $PLIST_DST"
echo ""
echo "🚀 通过 LaunchAgent 启动应用..."
sleep 1
if pgrep -f "$BIN_DIR/NetBar" >/dev/null; then
    echo "   ✅ 已启动最新版本"
else
    echo "   ⚠️  LaunchAgent 未立即启动，改用 open 启动"
    open "$APP_DIR"
fi
echo ""
echo "📌 常用命令:"
echo "   手动启动: open $APP_DIR"
echo "   停止进程: pkill NetBar"
echo "   卸载应用: launchctl unload $PLIST_DST && rm $PLIST_DST && rm -rf $APP_DIR"
