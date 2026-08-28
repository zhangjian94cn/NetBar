#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/appstore"
APP_DIR="$DIST_DIR/NetBar.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
ENTITLEMENTS="$ROOT_DIR/Resources/Entitlements/AppStore.entitlements"

cd "$ROOT_DIR"

echo "Building NetBar App Store Lite..."
swift build -c release -Xswiftc -DAPP_STORE

rm -rf "$DIST_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp "$ROOT_DIR/.build/release/NetBar" "$BIN_DIR/NetBar"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"

if find "$APP_DIR" \( -name 'netbar-mini-link-helper' -o -name 'install-netbar-mini-link-helper.command' -o -name 'NetBarMiniNetworkGuardian' -o -name 'netbar-route-safety-helper' \) | grep -q .; then
    echo "App Store Lite artifact must not contain network Helper or Guardian resources" >&2
    exit 1
fi
if strings "$BIN_DIR/NetBar" | grep -Fq '/usr/bin/ssh'; then
    echo "App Store Lite binary must not contain SSH provisioning capability" >&2
    exit 1
fi
if strings "$BIN_DIR/NetBar" | grep -Eq 'OverlayTransactions|Mihomo 拒绝切换 TUN|模式验证失败'; then
    echo "App Store Lite binary must not contain Clash mode write capability" >&2
    exit 1
fi

if [[ -n "${NETBAR_APPSTORE_IDENTITY:-}" ]]; then
    echo "Signing with App Store identity..."
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$NETBAR_APPSTORE_IDENTITY" "$APP_DIR"
else
    echo "NETBAR_APPSTORE_IDENTITY is not set; leaving app unsigned."
fi

echo "App Store Lite artifact: $APP_DIR"
