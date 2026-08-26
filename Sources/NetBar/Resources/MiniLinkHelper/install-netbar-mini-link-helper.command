#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
HELPER_SOURCE="$SCRIPT_DIR/netbar-mini-link-helper"
PROFILE_SOURCE="$SCRIPT_DIR/MacMiniLinkProfile.plist"
SUDOERS_SOURCE="$SCRIPT_DIR/com.zjah.NetBarMiniLinkHelper.sudoers"
GUARDIAN_SOURCE="$SCRIPT_DIR/NetBarMiniNetworkGuardian"
GUARDIAN_PLIST_SOURCE="$SCRIPT_DIR/com.zjah.NetBarMiniNetworkGuardian.plist"
HELPER_TARGET=/Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper
PROFILE_DIR=/Library/Application\ Support/NetBar
PROFILE_TARGET="$PROFILE_DIR/MacMiniLinkProfile.plist"
SUDOERS_TARGET=/etc/sudoers.d/netbar-mini-link-helper
LEGACY_SUDOERS_TARGET=/etc/sudoers.d/com.zjah.NetBarMiniLinkHelper
GUARDIAN_TARGET=/Library/PrivilegedHelperTools/com.zjah.NetBarMiniNetworkGuardian
GUARDIAN_PLIST_TARGET=/Library/LaunchDaemons/com.zjah.NetBarMiniNetworkGuardian.plist
INSTALL_USER="${USER}"
SUDOERS_TEMP="$(/usr/bin/mktemp /tmp/netbar-mini-helper-sudoers.XXXXXX)"
DNS_TEMP="$(/usr/bin/mktemp /tmp/netbar-mini-upstream-dns.XXXXXX)"

cleanup() {
    /bin/rm -f "$SUDOERS_TEMP" "$DNS_TEMP"
}
trap cleanup EXIT

[[ "$INSTALL_USER" == "zhangjian" ]] || {
    print -u2 -- "安装用户必须是 zhangjian，当前为 $INSTALL_USER"
    exit 1
}
[[ -f "$HELPER_SOURCE" && -f "$PROFILE_SOURCE" && -f "$SUDOERS_SOURCE" && -f "$GUARDIAN_SOURCE" && -f "$GUARDIAN_PLIST_SOURCE" ]] || {
    print -u2 -- "安装文件不完整"
    exit 1
}

UPSTREAM_DEVICE="$(/usr/bin/plutil -extract miniUpstreamDevice raw -o - "$PROFILE_SOURCE")"
UPSTREAM_ADDRESS="$(/usr/bin/plutil -extract miniUpstreamAddress raw -o - "$PROFILE_SOURCE")"
UPSTREAM_SUBNET="$(/usr/bin/plutil -extract miniUpstreamSubnetMask raw -o - "$PROFILE_SOURCE")"
UPSTREAM_ROUTER="$(/usr/bin/plutil -extract miniUpstreamRouter raw -o - "$PROFILE_SOURCE")"
UPSTREAM_SERVICE="$(/usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk -v device="$UPSTREAM_DEVICE" '
    /^\([0-9]+\) / { name=$0; sub(/^\([0-9]+\) /, "", name); sub(/^\*/, "", name) }
    $0 ~ "Device: " device "\\)$" { print name; exit }
')"
[[ -n "$UPSTREAM_SERVICE" ]] || {
    print -u2 -- "未找到设备为 $UPSTREAM_DEVICE 的上游网络服务"
    exit 1
}
UPSTREAM_INFO="$(/usr/sbin/networksetup -getinfo "$UPSTREAM_SERVICE")"
[[ "$UPSTREAM_INFO" == *"Manual Configuration"* &&
   "$UPSTREAM_INFO" == *"IP address: $UPSTREAM_ADDRESS"* &&
   "$UPSTREAM_INFO" == *"Subnet mask: $UPSTREAM_SUBNET"* &&
   "$UPSTREAM_INFO" == *"Router: $UPSTREAM_ROUTER"* ]] || {
    print -u2 -- "$UPSTREAM_SERVICE 配置与 NetBar Profile 不一致，已拒绝安装 Guardian"
    exit 1
}
/usr/sbin/networksetup -getdnsservers "$UPSTREAM_SERVICE" > "$DNS_TEMP"

/bin/cp "$SUDOERS_SOURCE" "$SUDOERS_TEMP"

echo "NetBar 需要一次管理员授权，以安装仅能管理雷雳网桥的受限 Helper。"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TEMP"
/usr/bin/sudo /bin/mkdir -p /Library/PrivilegedHelperTools "$PROFILE_DIR"
/usr/bin/sudo /bin/mkdir -p "$PROFILE_DIR/MiniGuardian"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$HELPER_SOURCE" "$HELPER_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$GUARDIAN_SOURCE" "$GUARDIAN_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0644 "$PROFILE_SOURCE" "$PROFILE_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0600 "$DNS_TEMP" "$PROFILE_DIR/MiniGuardian/upstream-dns-install-snapshot.txt"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0440 "$SUDOERS_TEMP" "$SUDOERS_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0644 "$GUARDIAN_PLIST_SOURCE" "$GUARDIAN_PLIST_TARGET"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TARGET"
/usr/bin/sudo /bin/rm -f "$LEGACY_SUDOERS_TARGET"
/usr/bin/sudo /bin/launchctl bootout system/com.zjah.NetBarMiniNetworkGuardian 2>/dev/null || true
/usr/bin/sudo /bin/launchctl bootstrap system "$GUARDIAN_PLIST_TARGET"
/usr/bin/sudo /bin/launchctl kickstart -k system/com.zjah.NetBarMiniNetworkGuardian
/usr/bin/sudo -n "$HELPER_TARGET" status
echo "NetBar Mini Link Helper 与上游自愈 Guardian 安装完成，可以关闭此窗口。"
