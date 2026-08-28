#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
HELPER_SOURCE="$SCRIPT_DIR/netbar-route-safety-helper"
SUDOERS_SOURCE="$SCRIPT_DIR/com.zjah.NetBarRouteSafetyHelper.sudoers"
HELPER_TARGET=/Library/PrivilegedHelperTools/com.zjah.NetBarRouteSafetyHelper
SUDOERS_TARGET=/etc/sudoers.d/netbar-route-safety-helper
TRANSACTION_DIR=/Library/Application\ Support/NetBar/RouteSafety
LEGACY_BACKUP="$TRANSACTION_DIR/service-order-backup.txt"
PENDING_TARGET="$TRANSACTION_DIR/pending-target.txt"
PENDING_KIND="$TRANSACTION_DIR/pending-kind.txt"
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
echo "NetBar 需要一次管理员授权，以安装只管理 Wi-Fi/雷雳优先级和 Mini 依赖 Wi-Fi DNS 的受限 Helper。"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TEMP"
/usr/bin/sudo /bin/mkdir -p /Library/PrivilegedHelperTools
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$HELPER_SOURCE" "$HELPER_TARGET"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0440 "$SUDOERS_TEMP" "$SUDOERS_TARGET"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TARGET"
if /usr/bin/sudo /bin/test -f "$LEGACY_BACKUP" &&
   ! /usr/bin/sudo /bin/test -f "$PENDING_TARGET" &&
   ! /usr/bin/sudo /bin/test -f "$PENDING_KIND"; then
    echo "正在迁移 Route Safety Helper v1 的已提交备份..."
    /usr/bin/sudo /bin/rm -f "$LEGACY_BACKUP"
fi
if /usr/bin/sudo /bin/test -f "$LEGACY_BACKUP" &&
   /usr/bin/sudo /bin/test -f "$PENDING_TARGET" &&
   ! /usr/bin/sudo /bin/test -f "$PENDING_KIND"; then
    echo "正在迁移 Route Safety Helper v2 的未完成路由事务..."
    print -r -- route | /usr/bin/sudo /usr/bin/tee "$PENDING_KIND" >/dev/null
    /usr/bin/sudo /bin/chmod 0600 "$PENDING_KIND"
fi
/usr/bin/sudo -n "$HELPER_TARGET" status
echo "NetBar Route Safety Helper 安装完成，可以关闭此窗口。"
