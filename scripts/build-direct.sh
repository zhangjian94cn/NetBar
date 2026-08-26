#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/direct"
APP_DIR="$DIST_DIR/NetBar.app"
ZIP_PATH="$DIST_DIR/NetBar-direct-full.zip"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
ENTITLEMENTS="$ROOT_DIR/Resources/Entitlements/Direct.entitlements"

cd "$ROOT_DIR"

echo "Building NetBar Direct Full..."
swift build -c release -Xswiftc -DDIRECT_FULL

rm -rf "$DIST_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp "$ROOT_DIR/.build/release/NetBar" "$BIN_DIR/NetBar"
cp -R "$ROOT_DIR/.build/release/NetBar_NetBar.bundle" "$RES_DIR/NetBar_NetBar.bundle"
cp "$ROOT_DIR/.build/release/NetBarMiniNetworkGuardian" "$RES_DIR/NetBar_NetBar.bundle/MiniLinkHelper/NetBarMiniNetworkGuardian"
chmod 0755 "$RES_DIR/NetBar_NetBar.bundle/MiniLinkHelper/NetBarMiniNetworkGuardian"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"

if [[ -n "${NETBAR_DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "Signing with Developer ID..."
    codesign --force --options runtime --sign "$NETBAR_DEVELOPER_ID_APPLICATION" "$RES_DIR/NetBar_NetBar.bundle/MiniLinkHelper/NetBarMiniNetworkGuardian"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$NETBAR_DEVELOPER_ID_APPLICATION" "$APP_DIR"
else
    echo "NETBAR_DEVELOPER_ID_APPLICATION is not set; leaving app unsigned."
fi

ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ -n "${NETBAR_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "Submitting to Apple notary service..."
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NETBAR_NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
else
    echo "NETBAR_NOTARY_KEYCHAIN_PROFILE is not set; skipping notarization."
fi

echo "Direct Full artifact: $ZIP_PATH"
