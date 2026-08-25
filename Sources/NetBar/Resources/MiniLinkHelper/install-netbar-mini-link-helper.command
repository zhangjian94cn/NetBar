#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
HELPER_SOURCE="$SCRIPT_DIR/netbar-mini-link-helper"
PROFILE_SOURCE="$SCRIPT_DIR/MacMiniLinkProfile.plist"
SUDOERS_SOURCE="$SCRIPT_DIR/com.zjah.NetBarMiniLinkHelper.sudoers"
HELPER_TARGET=/Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper
PROFILE_DIR=/Library/Application\ Support/NetBar
PROFILE_TARGET="$PROFILE_DIR/MacMiniLinkProfile.plist"
SUDOERS_TARGET=/etc/sudoers.d/com.zjah.NetBarMiniLinkHelper
INSTALL_USER="${USER}"
SUDOERS_TEMP="$(/usr/bin/mktemp /tmp/netbar-mini-helper-sudoers.XXXXXX)"

cleanup() {
    /bin/rm -f "$SUDOERS_TEMP"
}
trap cleanup EXIT

[[ "$INSTALL_USER" == "zhangjian" ]] || {
    print -u2 -- "安装用户必须是 zhangjian，当前为 $INSTALL_USER"
    exit 1
}
[[ -f "$HELPER_SOURCE" && -f "$PROFILE_SOURCE" && -f "$SUDOERS_SOURCE" ]] || {
    print -u2 -- "安装文件不完整"
    exit 1
}

/bin/cp "$SUDOERS_SOURCE" "$SUDOERS_TEMP"

echo "NetBar 需要一次管理员授权，以安装仅能管理雷雳网桥的受限 Helper。"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TEMP"
/usr/bin/sudo /bin/mkdir -p /Library/PrivilegedHelperTools "$PROFILE_DIR"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$HELPER_SOURCE" "$HELPER_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0644 "$PROFILE_SOURCE" "$PROFILE_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0440 "$SUDOERS_TEMP" "$SUDOERS_TARGET"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TARGET"
/usr/bin/sudo -n "$HELPER_TARGET" status
echo "NetBar Mini Link Helper 安装完成，可以关闭此窗口。"
