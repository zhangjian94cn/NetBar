#!/bin/zsh
set -euo pipefail

SSH=/usr/bin/ssh
PLUTIL=/usr/bin/plutil
IFCONFIG=/sbin/ifconfig
PING=/sbin/ping
SWIFT=/usr/bin/swift
ROOT_DIR="${0:A:h:h}"
REMOTE_HOST=192.168.2.1
REMOTE_USER=zhangjian
HELPER=/Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper

fail() {
    print -u2 -- "$1"
    exit 1
}

remote() {
    "$SSH" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=yes \
        -o HostKeyAlias=192.168.2.1 \
        "$REMOTE_USER@$REMOTE_HOST" "$@"
}

json_value() {
    local key="$1" json="$2"
    print -rn -- "$json" | "$PLUTIL" -extract "$key" raw -o - -- -
}

sharing_facts_consistency() {
    local helper_json launch_output live_process live_forwarding helper_process helper_forwarding conflict
    helper_json="$(remote /usr/bin/sudo -n "$HELPER" status)" || fail "Mini Helper v4 status unavailable"
    [[ "$(json_value protocolVersion "$helper_json")" == "4" ]] || fail "Mini Helper protocol is not v4"
    launch_output="$(remote /bin/launchctl print system/com.apple.NetworkSharing 2>/dev/null || true)"
    [[ "$launch_output" == *"state = running"* && "$launch_output" == *"/usr/libexec/InternetSharing"* ]] \
        && live_process=true || live_process=false
    live_forwarding="$(remote /usr/sbin/sysctl -n net.inet.ip.forwarding 2>/dev/null || true)"
    helper_process="$(json_value sharingProcessRunning "$helper_json")"
    helper_forwarding="$(json_value forwardingEnabled "$helper_json")"
    conflict="$(json_value evidenceConflict "$helper_json")"
    [[ "$helper_process" == "$live_process" ]] || fail "sharing process evidence mismatch"
    [[ "$helper_forwarding" == "$([[ "$live_forwarding" == "1" ]] && print true || print false)" ]] \
        || fail "kernel forwarding evidence mismatch"
    [[ "$conflict" == "false" ]] || fail "Helper reports remote evidence conflict"
    print -- "sharing-facts-consistency: PASS process=$helper_process forwarding=$helper_forwarding"
}

mini_end_to_end_readiness() {
    sharing_facts_consistency
    local bridge_output success=false target
    bridge_output="$($IFCONFIG bridge0 2>/dev/null || true)"
    [[ "$bridge_output" == *"status: active"* ]] || fail "bridge0 carrier inactive"
    [[ "$bridge_output" == *"inet 192.168.2.2 "* ]] || fail "bridge0 fixed address missing"
    "$PING" -b bridge0 -S 192.168.2.2 -c 1 -W 700 192.168.2.1 >/dev/null \
        || fail "Mac mini peer unreachable"
    for target in 1.1.1.1 114.114.114.114; do
        if "$PING" -b bridge0 -S 192.168.2.2 -c 1 -W 700 "$target" >/dev/null 2>&1; then
            success=true
            break
        fi
    done
    [[ "$success" == "true" ]] || fail "MacBook downstream egress unavailable through bridge0"
    print -- "mini-end-to-end-readiness: PASS peer=true downstream=true"
}

network_trace_replay() {
    (cd "$ROOT_DIR" && "$SWIFT" test --filter NetworkRoutePolicyTests/testDownstreamFailureStartsEpisodeAndReportsGuardianOnlyOnceWhenWiFiFallbackFails)
    print -- "network-trace-replay: PASS stable fallback episode reached without repeated report/log effects"
}

[[ "$#" -eq 1 ]] || fail "usage: network-readiness-diagnostics.sh sharing-facts-consistency|mini-end-to-end-readiness|network-trace-replay"
case "$1" in
    sharing-facts-consistency) sharing_facts_consistency ;;
    mini-end-to-end-readiness) mini_end_to_end_readiness ;;
    network-trace-replay) network_trace_replay ;;
    *) fail "unsupported diagnostic command" ;;
esac
