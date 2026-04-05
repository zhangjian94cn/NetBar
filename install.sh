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
swift build -c release

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

# 从 .env 导入 VPS 配置到 UserDefaults
if [ -f "$SCRIPT_DIR/.env" ]; then
    echo "🔑 从 .env 导入 VPS 配置..."
    while IFS='=' read -r key value; do
        # 跳过注释和空行
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        # 去除可能的空格
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        case "$key" in
            VPS_BWG_HOST) defaults write com.zjah.NetBar vps_bwg_host "$value" ;;
            VPS_BWG_PORT) defaults write com.zjah.NetBar vps_bwg_port -int "$value" ;;
            VPS_BWG_PATH) defaults write com.zjah.NetBar vps_bwg_path "$value" ;;
            VPS_BWG_USER) defaults write com.zjah.NetBar vps_bwg_user "$value" ;;
            VPS_BWG_PASS) defaults write com.zjah.NetBar vps_bwg_pass "$value" ;;
        esac
    done < "$SCRIPT_DIR/.env"
    echo "   ✅ VPS 配置已写入 UserDefaults"
else
    echo "⚠️  未找到 .env，VPS 流量监控将不可用"
    echo "   请创建 .env 文件，参考 .env.example"
fi

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
echo "🚀 重新启动应用..."
open "$APP_DIR"
echo "   ✅ 已启动最新版本"
echo ""
echo "📌 常用命令:"
echo "   手动启动: open $APP_DIR"
echo "   停止进程: pkill NetBar"
echo "   卸载应用: launchctl unload $PLIST_DST && rm $PLIST_DST && rm -rf $APP_DIR"
