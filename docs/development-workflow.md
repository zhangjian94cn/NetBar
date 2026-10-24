# Development and delivery

NetBar uses Forgejo for task branches and pull requests, Drone for native macOS checks, and GitHub as a **main-only** mirror. Existing GitHub branches and tags remain historical references.

1. Create a task branch from current Forgejo main; push only to `personal`.
2. Open a Forgejo PR. Drone runs Swift build, Direct Full and App Store Lite tests, coverage, Helper contracts and both packages.
3. Use the canonical Skills `merge-to-main` owner with this repository and the `netbar` platform profile. It verifies all frozen suite artifacts and exact PR head/base/tested tree before merging.
4. The existing mirror owner fast-forwards GitHub main. It never copies task branches or new tags and never forces divergence.

[Platform binding](../config/repository-platform.json), [suite registry](../config/verification-suites.json), and [shared verifier lock](../config/verification-engine.json) are authoritative. The shared engine owns plan/aggregate policy; [NetBar commands](../scripts/ci-checks.sh) own product checks. The user-level macOS runner is restricted to this trusted repository, with capacity one. It does not install NetBar or manage network settings.

CI needs the registered Mac online. Missing runners or artifacts are pending, never a reason to waive a check. Forgejo Drone build 3 passed all seven native suites before GitHub automatic CI was disabled. The original GitHub workflow is retained for explicit historical/manual use only. Rollback preserves new commits, original refs and private platform/runner backups; it never force-pushes either main.

Native test suites create an unlocked, disposable fixture keychain and address it explicitly. Run `bash scripts/ci-checks.sh direct-tests`, `lite-tests`, or `coverage`; the retained GitHub manual workflow uses these same commands. Direct and Lite test commands accept Swift test arguments, for example `bash scripts/ci-checks.sh direct-tests -c release --filter KeychainHelperTests`.

XCTest processes require a valid fixture even in release tests. A missing variable, absent file or invalid keychain returns an error before credential access; tests never fall back to the login keychain. Every storage entry point suppresses Security interaction and restores the prior process setting. Saves update in place so failed writes preserve existing values. Installed release packages ignore the fixture environment. The fixture file is deleted on suite exit, without resetting, unlocking or selecting the login keychain.
