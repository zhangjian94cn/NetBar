#!/usr/bin/env bash
# Commands belong to NetBar; plan binding and aggregation belong to the locked Skills verifier.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Native macOS is required' >&2; exit 2; }
# A fresh disposable keychain stores only fixtures. Never unlock or select login.keychain.
case "${1:-}" in
  direct-tests|lite-tests|coverage)
    ci_keychain_dir="$(mktemp -d)"
    chmod 700 "$ci_keychain_dir"
    export NETBAR_CI_KEYCHAIN="$ci_keychain_dir/fixtures.keychain-db"
    trap 'security delete-keychain "$NETBAR_CI_KEYCHAIN" >/dev/null 2>&1 || true; rm -rf "$ci_keychain_dir"' EXIT
    security create-keychain -p '' "$NETBAR_CI_KEYCHAIN"
    security unlock-keychain -p '' "$NETBAR_CI_KEYCHAIN"
    ;;
esac
case "${1:-}" in
  build) swift build ;;
  direct-tests) swift test "${@:2}" ;;
  lite-tests) swift test -Xswiftc -DAPP_STORE "${@:2}" ;;
  coverage)
    swift test --enable-code-coverage
    bin_dir="$(swift build --show-bin-path)"
    profile="$bin_dir/codecov/default.profdata"
    test_bundle="$(find "$bin_dir" -maxdepth 1 -name '*.xctest' -print -quit)"
    test -n "$test_bundle"
    xcrun llvm-cov report "$test_bundle/Contents/MacOS/$(basename "$test_bundle" .xctest)" \
      -instr-profile "$profile" -ignore-filename-regex='(Tests|\.build)/' | tail -25
    ;;
  helper-contracts)
    zsh -n Sources/NetBar/Resources/MiniLinkHelper/netbar-mini-link-helper
    zsh -n Sources/NetBar/Resources/MiniLinkHelper/install-netbar-mini-link-helper.command
    plutil -lint Sources/NetBar/Resources/MiniLinkHelper/MacMiniLinkProfile.plist
    /usr/sbin/visudo -cf Sources/NetBar/Resources/MiniLinkHelper/com.zjah.NetBarMiniLinkHelper.sudoers
    zsh -n Sources/NetBar/Resources/RouteSafetyHelper/netbar-route-safety-helper
    zsh -n Sources/NetBar/Resources/RouteSafetyHelper/install-netbar-route-safety-helper.command
    zsh -n scripts/network-readiness-diagnostics.sh
    sudoers_file="$(mktemp)"
    trap 'rm -f "$sudoers_file"' EXIT
    sed 's/__USER__/ciuser/g' Sources/NetBar/Resources/RouteSafetyHelper/com.zjah.NetBarRouteSafetyHelper.sudoers > "$sudoers_file"
    /usr/sbin/visudo -cf "$sudoers_file"
    ;;
  direct-package)
    ./scripts/build-direct.sh
    test -x dist/direct/NetBar.app/Contents/MacOS/NetBar
    test -f dist/direct/NetBar.app/Contents/Resources/NetBar_NetBar.bundle/MiniLinkHelper/netbar-mini-link-helper
    ;;
  lite-package)
    ./scripts/build-appstore.sh
    test -x dist/appstore/NetBar.app/Contents/MacOS/NetBar
    test -z "$(find dist/appstore/NetBar.app -type f \( -name 'netbar-mini-link-helper' -o -name 'install-netbar-mini-link-helper.command' \) -print -quit)"
    strings_file="$(mktemp)"
    trap 'rm -f "$strings_file"' EXIT
    strings dist/appstore/NetBar.app/Contents/MacOS/NetBar > "$strings_file"
    ! grep -Fq '/usr/bin/ssh' "$strings_file"
    ;;
  *) echo 'Unknown NetBar CI suite' >&2; exit 2 ;;
esac
