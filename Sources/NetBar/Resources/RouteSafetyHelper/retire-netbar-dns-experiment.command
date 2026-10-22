#!/bin/zsh
# One-time migration. No DNS writes, no Clash or VPN writes, no AX permission.
set -euo pipefail
if (( EUID != 0 )); then
    exec /usr/bin/sudo /bin/zsh "${0:A}" --retire-dns-only
fi
[[ "$#" == 1 && "$1" == --retire-dns-only ]] || { print -u2 -- 'unsupported invocation'; exit 1; }
umask 077
source_dir="${0:A:h}"
state_dir='/Library/Application Support/NetBar/RouteSafety'
helper='/Library/PrivilegedHelperTools/com.zjah.NetBarRouteSafetyHelper'
guardian='/Library/PrivilegedHelperTools/com.zjah.NetBarDNSGuardian'
plist='/Library/LaunchDaemons/com.zjah.NetBarDNSGuardian.plist'
sudoers='/etc/sudoers.d/netbar-route-safety-helper'
label='system/com.zjah.NetBarDNSGuardian'
fail() { print -u2 -- "manual_pending: $1"; exit 1; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
[[ -d "$state_dir" && ! -L "$state_dir" && "$(/usr/bin/stat -f %u "$state_dir")" == 0 ]] || fail 'unsafe state directory'
[[ ! -e "$state_dir/dns-lease.json" && ! -e "$state_dir/dns-installing" && ! -e "$state_dir/pending-kind.txt" ]] || fail 'unfinished lease/install/route transaction; preserve originals'
/usr/bin/pgrep -x NetBar >/dev/null && fail 'quit NetBar before retiring the experiment'
console_user="$(/usr/bin/stat -f %Su /dev/console)"
[[ "$console_user" =~ '^[A-Za-z0-9._-]+$' && "$console_user" != root ]] || fail 'console identity unknown'
console_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
clash_root="$console_home/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
# The native app must already have turned both switches off, with known automatic
# DNS restored on both physical services. Nothing here attempts to repair them.
/usr/bin/ruby -ryaml -e 'x=YAML.safe_load(File.read(ARGV[0]),aliases:true);abort "TUN/proxy not off" unless x["enable_tun_mode"]==false && x["enable_system_proxy"]==false' "$clash_root/verge.yaml" || fail 'close TUN and system proxy in Clash first'
for service in 'Wi-Fi' 'Thunderbolt Bridge'; do
    dns_value="$(/usr/sbin/networksetup -getdnsservers "$service")"
    [[ "$dns_value" == "There aren't any DNS Servers set on $service." ]] || fail "DNS original not verified automatic on $service"
done
if [[ -e "$guardian" ]]; then
    [[ -f "$guardian" && ! -L "$guardian" && "$(/usr/bin/stat -f %u "$guardian")" == 0 ]] || fail 'unsafe Guardian'
    guardian_status="$("$guardian" dns-status)" || fail 'cannot read old recovery status'
    print -r -- "$guardian_status" | /usr/bin/plutil -extract dnsLeaseState raw -o - - | /usr/bin/grep -qx inactive || fail 'old lease not inactive'
    [[ "$(print -r -- "$guardian_status" | /usr/bin/plutil -extract dnsLeaseServices raw -o - -)" == 0 ]] || fail 'unrestored services'
fi
[[ -f "$state_dir/execution.lock" && ! -L "$state_dir/execution.lock" ]] || fail 'writer lock unavailable'
zmodload zsh/system
zsystem flock -t 0 -f retire_lock "$state_dir/execution.lock" || fail 'helper busy'
[[ ! -e "$state_dir/dns-lease.json" ]] || fail 'lease appeared concurrently'
backup="$(/usr/bin/mktemp -d "$state_dir/dns-retirement.XXXXXX")"
/bin/chmod 0700 "$backup"
typeset -A before applied retired
had_task=false
for target in "$helper" "$sudoers" "$guardian" "$plist"; do
    [[ ! -e "$target" ]] && continue
    [[ -f "$target" && ! -L "$target" && "$(/usr/bin/stat -f %u "$target")" == 0 ]] || fail "unsafe component $target"
    before[$target]="$(sha "$target")"
    /bin/cp -p "$target" "$backup/${target:t}"
    /bin/chmod 0600 "$backup/${target:t}"
    printf '%s\t%s\t%s\n' "$target" "${before[$target]}" "$(/usr/bin/stat -f %Lp "$target")" >> "$backup/original.tsv"
done
# Remove exactly the known dispatch and fixed DNS verbs, preserving all original
# route actions. Unexpected installed content is never replaced wholesale.
/usr/bin/ruby -e '
s=File.read(ARGV[0]);s=s.gsub("|dns-status|dns-prepare|dns-acquire|dns-release|dns-reconcile","")
a=s.index("# DNS lease actions");b=s.index("# Serializes writers",a||0);s=s[0...a]+s[b..] if a && b
File.write(ARGV[1],s)
' "$helper" "$backup/helper-candidate"
/usr/bin/cmp -s "$backup/helper-candidate" "$source_dir/netbar-route-safety-helper" || fail "installed route Helper changed; inspect $backup"
/usr/bin/awk '!/com.zjah.NetBarRouteSafetyHelper dns-(status|prepare|acquire|release|reconcile)$/' "$sudoers" > "$backup/sudoers-candidate"
/usr/sbin/visudo -cf "$backup/sudoers-candidate"
# Record a concrete CAS recovery command, requiring local administrator review.
cat > "$backup/README.txt" <<EOF
DNS-only experiment retired. No DNS, Clash, VPN or Mini settings were written.
original.tsv records original paths, SHA256 and permissions; applied.tsv records installed replacements.
Before restoring anything: quit NetBar, turn off Clash TUN/proxy, verify DNS and no active transactions.
Restore only if each current hash still matches applied.tsv (retired Guardian/plist must still be absent).
Then install original files with permissions in original.tsv, validate sudoers, and bootstrap saved plist only if intentionally returning to the old experiment.
Do not overwrite external changes. Keep manual_pending and inspect the smallest conflicting path.
EOF
# Failures retain recovery artifacts. Roll back only our exact applied bytes.
committed=false
cleanup() {
    local rc=$? target
    if (( rc != 0 )) && [[ "$committed" == false ]]; then
        for target in "${(@k)applied}"; do
            if [[ -f "$target" && "$(sha "$target")" == "${applied[$target]}" ]]; then
                mode="$(/usr/bin/awk -F '\t' -v p="$target" '$1==p {print $3}' "$backup/original.tsv")"
                /usr/bin/install -o root -g wheel -m "$mode" "$backup/${target:t}" "$target" || true
            fi
        done
        for target in "${(@k)retired}"; do
            if [[ ! -e "$target" && "$(sha "$backup/retired-${target:t}")" == "${before[$target]}" ]]; then
                mode="$(/usr/bin/awk -F '\t' -v p="$target" '$1==p {print $3}' "$backup/original.tsv")"
                /usr/bin/install -o root -g wheel -m "$mode" "$backup/retired-${target:t}" "$target" || true
            fi
        done
        if [[ "$had_task" == true && -f "$plist" && "$(sha "$plist")" == "${before[$plist]}" ]]; then
            /bin/launchctl bootstrap system "$plist" 2>/dev/null || true
        fi
        print -u2 -- "manual_pending: retirement incomplete; preserved recovery point $backup"
    fi
}
trap cleanup EXIT
for target in "$helper" "$sudoers" "$guardian" "$plist"; do
    [[ -z "${before[$target]:-}" ]] || [[ "$(sha "$target")" == "${before[$target]}" ]] || fail 'external component change'
done
if /bin/launchctl print "$label" >/dev/null 2>&1; then
    had_task=true
    /bin/launchctl bootout "$label" || fail 'cannot unload DNS task'
fi
/bin/launchctl print "$label" >/dev/null 2>&1 && fail 'DNS task remains registered'
for target candidate mode in "$helper" "$backup/helper-candidate" 0755 "$sudoers" "$backup/sudoers-candidate" 0440; do
    [[ "$(sha "$target")" == "${before[$target]}" ]] || fail 'concurrent component write'
    digest="$(sha "$candidate")"
    /usr/bin/install -o root -g wheel -m "$mode" "$candidate" "$target.netbar-retire.$$"
    /bin/mv "$target.netbar-retire.$$" "$target"
    applied[$target]="$digest"
    printf '%s\t%s\n' "$target" "$digest" >> "$backup/applied.tsv"
done
/usr/sbin/visudo -cf "$sudoers"
for target in "$guardian" "$plist"; do
    [[ ! -e "$target" ]] && continue
    [[ "$(sha "$target")" == "${before[$target]}" ]] || fail 'concurrent DNS component change'
    /bin/mv "$target" "$backup/retired-${target:t}"
    retired[$target]=true
    /bin/chmod 0600 "$backup/retired-${target:t}"
done
"$helper" status > "$backup/route-status.json"
committed=true
print -r -- "Retirement complete. Route Helper preserved. Private recovery point: $backup"
