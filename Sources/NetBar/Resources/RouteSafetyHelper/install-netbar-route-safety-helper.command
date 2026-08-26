#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
HELPER_SOURCE="$SCRIPT_DIR/netbar-route-safety-helper"
SUDOERS_SOURCE="$SCRIPT_DIR/com.zjah.NetBarRouteSafetyHelper.sudoers"
HELPER_TARGET=/Library/PrivilegedHelperTools/com.zjah.NetBarRouteSafetyHelper
SUDOERS_TARGET=/etc/sudoers.d/netbar-route-safety-helper
INSTALL_USER="$(/usr/bin/stat -f %Su /dev/console)"
SUDOERS_TEMP="$(/usr/bin/mktemp /tmp/netbar-route-helper-sudoers.XXXXXX)"

cleanup() { /bin/rm -f "$SUDOERS_TEMP"; }
trap cleanup EXIT

[[ "$INSTALL_USER" =~ '^[A-Za-z0-9._-]+$' ]] || {
    print -u2 -- "无法验证本地控制台用户"
    exit 1
}
[[ -f "$HELPER_SOURCE" && -f "$SUDOERS_SOURCE" ]] || {
    print -u2 -- "安装文件不完整"
    exit 1
}

/usr/bin/sed "s/__USER__/$INSTALL_USER/g" "$SUDOERS_SOURCE" > "$SUDOERS_TEMP"
echo "NetBar 需要一次管理员授权，以安装只能切换 Wi-Fi/雷雳优先级的受限 Helper。"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TEMP"
/usr/bin/sudo /bin/mkdir -p /Library/PrivilegedHelperTools
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$HELPER_SOURCE" "$HELPER_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0440 "$SUDOERS_TEMP" "$SUDOERS_TARGET"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TARGET"
/usr/bin/sudo -n "$HELPER_TARGET" status
echo "NetBar Route Safety Helper 安装完成，可以关闭此窗口。"
