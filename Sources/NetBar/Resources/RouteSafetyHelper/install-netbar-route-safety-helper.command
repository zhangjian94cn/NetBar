#!/bin/zsh
set -euo pipefail

# One native terminal authorization; root then holds the same POSIX writer lock as
# both Helper implementations. No administrator password enters NetBar or a file.
if (( EUID != 0 )); then
    exec /usr/bin/sudo /bin/zsh "${0:A}" --privileged-install
fi
[[ "$#" -eq 1 && "$1" == --privileged-install ]] || { print -u2 -- "unsupported installer invocation"; exit 1; }

SCRIPT_DIR="${0:A:h}"
HELPER_SOURCE="$SCRIPT_DIR/netbar-route-safety-helper"
SUDOERS_SOURCE="$SCRIPT_DIR/com.zjah.NetBarRouteSafetyHelper.sudoers"
DNS_GUARDIAN_SOURCE="$SCRIPT_DIR/NetBarDNSGuardian"
DNS_PLIST_SOURCE="$SCRIPT_DIR/com.zjah.NetBarDNSGuardian.plist"
PROFILE_SOURCE="$SCRIPT_DIR/../MiniLinkHelper/MacMiniLinkProfile.plist"
HELPER_TARGET=/Library/PrivilegedHelperTools/com.zjah.NetBarRouteSafetyHelper
SUDOERS_TARGET=/etc/sudoers.d/netbar-route-safety-helper
DNS_GUARDIAN_TARGET=/Library/PrivilegedHelperTools/com.zjah.NetBarDNSGuardian
DNS_PLIST_TARGET=/Library/LaunchDaemons/com.zjah.NetBarDNSGuardian.plist
TRANSACTION_DIR=/Library/Application\ Support/NetBar/RouteSafety
LEGACY_BACKUP="$TRANSACTION_DIR/service-order-backup.txt"
PENDING_TARGET="$TRANSACTION_DIR/pending-target.txt"
PENDING_KIND="$TRANSACTION_DIR/pending-kind.txt"
INSTALL_USER="$(/usr/bin/stat -f %Su /dev/console)"
SUDOERS_TEMP="$(/usr/bin/mktemp /tmp/netbar-route-helper-sudoers.XXXXXX)"
typeset -A APPLIED_DIGESTS ORIGINAL_DIGESTS ORIGINAL_MODES
install_backup=''
installation_committed=false
INSTALL_LOCK_FD=''
INSTALL_SENTINEL="$TRANSACTION_DIR/dns-installing"
INSTALL_SENTINEL_OWNED=false

cleanup() {
    local exit_status=$? target current backup_digest safe=true
    /bin/rm -f "$SUDOERS_TEMP"
    if (( exit_status != 0 )) && [[ -n "$install_backup" && "$installation_committed" == false ]]; then
        set +e
        # Restore only files still equal to this install's own applied bytes.
        for target in "${(@k)APPLIED_DIGESTS}"; do
            current="$(/usr/bin/sudo /usr/bin/shasum -a 256 "$target" 2>/dev/null | /usr/bin/awk '{print $1}')"
            [[ -z "${ORIGINAL_DIGESTS[$target]:-}" || "$current" != "${ORIGINAL_DIGESTS[$target]}" ]] || continue
            [[ "$current" == "${APPLIED_DIGESTS[$target]}" ]] || { safe=false; continue; }
            if [[ -n "${ORIGINAL_DIGESTS[$target]:-}" ]]; then
                backup_digest="$(/usr/bin/sudo /usr/bin/shasum -a 256 "$install_backup/${target:t}" | /usr/bin/awk '{print $1}')"
                [[ "$backup_digest" == "${ORIGINAL_DIGESTS[$target]}" ]] || { safe=false; continue; }
                /usr/bin/sudo /usr/bin/install -o root -g wheel -m "${ORIGINAL_MODES[$target]}" "$install_backup/${target:t}" "$target" || safe=false
            else
                /usr/bin/sudo /bin/rm -f "$target" || safe=false
            fi
        done
        if [[ "$safe" == true ]]; then
            /usr/bin/sudo /bin/launchctl bootout system/com.zjah.NetBarDNSGuardian 2>/dev/null
            [[ ! -f "$DNS_PLIST_TARGET" ]] || /usr/bin/sudo /bin/launchctl bootstrap system "$DNS_PLIST_TARGET"
            echo "安装失败，已恢复本次拥有的组件文件。备份：$install_backup"
        else
            echo "manual_pending：检测到外部组件变化，未覆盖；恢复点：$install_backup"
        fi
    fi
    if [[ "$INSTALL_SENTINEL_OWNED" == true ]]; then
        /bin/rm -f "$INSTALL_SENTINEL"
    fi
}
trap cleanup EXIT

install_component() {
    local source="$1" target="$2" mode="$3" candidate="$2.netbar-install.$$" digest current
    digest="$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{print $1}')"
    /usr/bin/sudo /usr/bin/install -o root -g wheel -m "$mode" "$source" "$candidate"
    [[ "$(/usr/bin/sudo /usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')" == "$digest" ]]
    current="$(/usr/bin/sudo /usr/bin/shasum -a 256 "$target" 2>/dev/null | /usr/bin/awk '{print $1}' || true)"
    [[ "$current" == "${ORIGINAL_DIGESTS[$target]:-}" ]] || { echo "组件在安装期间被外部修改：$target"; return 1; }
    print -r -- "$target\t$digest\t$mode" | /usr/bin/sudo /usr/bin/tee -a "$install_backup/applied.tsv" >/dev/null
    /usr/bin/sudo /bin/chmod 0600 "$install_backup/applied.tsv"
    /usr/bin/sudo /bin/mv -f "$candidate" "$target"
    APPLIED_DIGESTS[$target]="$digest"
}

[[ "$INSTALL_USER" =~ '^[A-Za-z0-9._-]+$' ]] || {
    print -u2 -- "无法验证本地控制台用户"
    exit 1
}
[[ -f "$HELPER_SOURCE" && -f "$SUDOERS_SOURCE" && -f "$PROFILE_SOURCE" && -f "$DNS_GUARDIAN_SOURCE" && -f "$DNS_PLIST_SOURCE" ]] || {
    print -u2 -- "安装文件不完整"
    exit 1
}

/usr/bin/sed "s/__USER__/$INSTALL_USER/g" "$SUDOERS_SOURCE" > "$SUDOERS_TEMP"
echo "NetBar 需要一次管理员授权，以安装受限网络 Helper 与 DNS 退出恢复组件。不接收或保存管理员密码。"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TEMP"
/usr/bin/plutil -lint "$DNS_PLIST_SOURCE"
for protected_directory in "/Library/Application Support/NetBar" "$TRANSACTION_DIR"; do
    if [[ -e "$protected_directory" ]]; then
        [[ -d "$protected_directory" && ! -L "$protected_directory" && "$(/usr/bin/stat -f %u "$protected_directory")" == 0 ]] || { echo "拒绝不安全的 root 状态目录"; exit 1; }
    else
        /bin/mkdir "$protected_directory"
    fi
done
/bin/chmod 0700 "$TRANSACTION_DIR"
[[ ! -L "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR/execution.lock" ]] || { echo "拒绝不安全的安装状态路径"; exit 1; }
[[ -f "$TRANSACTION_DIR/execution.lock" ]] || : > "$TRANSACTION_DIR/execution.lock"
/bin/chmod 0600 "$TRANSACTION_DIR/execution.lock"
zmodload zsh/system
zsystem flock -t 0 -f INSTALL_LOCK_FD "$TRANSACTION_DIR/execution.lock" || { echo "Helper 正忙，请稍后重试安装。"; exit 1; }
[[ ! -e "$INSTALL_SENTINEL" ]] || { echo "已有安装待恢复：$INSTALL_SENTINEL"; exit 1; }
print -r -- "$$" > "$INSTALL_SENTINEL"
/bin/chmod 0600 "$INSTALL_SENTINEL"
INSTALL_SENTINEL_OWNED=true
# The old release action takes the writer lock itself. The sentinel prevents a new
# acquisition in this short gap; the lock is held again before stopping recovery.
zsystem flock -u "$INSTALL_LOCK_FD"
INSTALL_LOCK_FD=''
if [[ -f "$DNS_GUARDIAN_TARGET" ]]; then
    # Updating recovery code while a lease is owned would remove the crash safety net.
    dns_release="$(/usr/bin/sudo "$DNS_GUARDIAN_TARGET" dns-release)"
    dns_remaining="$(print -r -- "$dns_release" | /usr/bin/plutil -extract dnsLeaseServices raw -o - -)"
    [[ "$dns_remaining" == 0 ]] || { echo "DNS 仍有待恢复项目，请先完成 DNS 释放后重试。"; exit 1; }
fi
zsystem flock -t 0 -f INSTALL_LOCK_FD "$TRANSACTION_DIR/execution.lock" || { echo "Helper 正忙，安装未变更组件。"; exit 1; }
[[ ! -e "$TRANSACTION_DIR/dns-lease.json" ]] || { echo "DNS lease 仍在，未替换恢复组件。"; exit 1; }
/usr/bin/sudo /bin/mkdir -p /Library/PrivilegedHelperTools
/usr/bin/sudo /bin/mkdir -p "/Library/Application Support/NetBar"
/usr/bin/sudo /bin/mkdir -p "$TRANSACTION_DIR"
/usr/bin/sudo /bin/chmod 0700 "$TRANSACTION_DIR"
# Privileged install recovery point, never a repository or user-readable directory.
install_backup="$(/usr/bin/sudo /usr/bin/mktemp -d "$TRANSACTION_DIR/helper-install.XXXXXX")"
for previous in "$HELPER_TARGET" "$DNS_GUARDIAN_TARGET" "$DNS_PLIST_TARGET" "$SUDOERS_TARGET" "/Library/Application Support/NetBar/MacMiniLinkProfile.plist"; do
    if /usr/bin/sudo /bin/test -f "$previous"; then
        ORIGINAL_DIGESTS[$previous]="$(/usr/bin/sudo /usr/bin/shasum -a 256 "$previous" | /usr/bin/awk '{print $1}')"
        ORIGINAL_MODES[$previous]="$(/usr/bin/sudo /usr/bin/stat -f %Lp "$previous")"
        /usr/bin/sudo /bin/cp -p "$previous" "$install_backup/${previous:t}"
        /usr/bin/sudo /bin/chmod 0600 "$install_backup/${previous:t}"
        print -r -- "$previous\t${ORIGINAL_DIGESTS[$previous]}\t${ORIGINAL_MODES[$previous]}" | /usr/bin/sudo /usr/bin/tee -a "$install_backup/original.tsv" >/dev/null
        /usr/bin/sudo /bin/chmod 0600 "$install_backup/original.tsv"
    fi
done
/usr/bin/sudo /bin/launchctl bootout system/com.zjah.NetBarDNSGuardian 2>/dev/null || true
install_component "$HELPER_SOURCE" "$HELPER_TARGET" 0755
install_component "$DNS_GUARDIAN_SOURCE" "$DNS_GUARDIAN_TARGET" 0755
install_component "$DNS_PLIST_SOURCE" "$DNS_PLIST_TARGET" 0644
install_component "$PROFILE_SOURCE" "/Library/Application Support/NetBar/MacMiniLinkProfile.plist" 0644
install_component "$SUDOERS_TEMP" "$SUDOERS_TARGET" 0440
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS_TARGET"
for log_path in /var/log/netbar-dns-guardian.log /var/log/netbar-dns-guardian.err; do
    /usr/bin/sudo /usr/bin/touch "$log_path"
    /usr/bin/sudo /usr/sbin/chown root:wheel "$log_path"
    /usr/bin/sudo /bin/chmod 0600 "$log_path"
done
/usr/bin/sudo /bin/launchctl bootstrap system "$DNS_PLIST_TARGET"
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
# dns-status takes the lock; defer its readback until component transaction commits.
installation_committed=true
/bin/rm -f "$INSTALL_SENTINEL"
INSTALL_SENTINEL_OWNED=false
zsystem flock -u "$INSTALL_LOCK_FD"
INSTALL_LOCK_FD=''
/usr/bin/sudo -n "$HELPER_TARGET" status
/usr/bin/sudo -n "$HELPER_TARGET" dns-status
echo "NetBar Route Safety Helper 安装完成，可以关闭此窗口。"
