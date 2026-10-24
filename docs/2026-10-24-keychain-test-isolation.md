# Keychain test isolation and noninteractive failure

Status: Implemented with local native validation; platform delivery is recorded in the PR and merge receipt.

## User stories and acceptance

- A Mac user can leave native CI running without system credential dialogs. Every
  storage entry point disables legacy Security interaction and restores the prior
  process setting after success or failure.
- Tests cannot read or change personal credentials. The existing
  [native test commands](../scripts/ci-checks.sh) provide an explicit disposable
  keychain; XCTest without that scope returns an error before querying storage,
  in both debug and release configurations.
- A missing or locked fixture fails promptly. An unsuccessful update preserves
  the existing credential, and normal reads, updates and deletes still work.

The reported `ping0_api_key` and `com.zjah.NetBar.test_key_<UUID>` dialogs came from
native Drone tests. The login keychain was present and accessible from the user's
interactive session; resetting it is not a remedy for an unscoped test process.

## Implementation and verification

The existing CI fixture scope is retained. [KeychainHelper](../Sources/NetBar/Utilities/KeychainHelper.swift)
applies noninteractive access to every entry point and uses update-before-add for
legacy saves as well as checked writes. Invalid fixture configuration returns an
error instead of aborting or falling back to the user's keychain. The fixture
environment is ignored by release packages.

[Regression tests](../Tests/NetBarTests/KeychainHelperTests.swift) exercise real
Security.framework operations against the disposable store, locked-store value
preservation, and bounded child XCTest processes with missing/invalid scopes.
The retained [GitHub manual workflow](../.github/workflows/ci.yml) calls the same
fixture-owning commands as Drone rather than invoking unscoped Swift tests.

## Native validation on 2026-10-24

| Check | Result |
| --- | --- |
| Direct Full tests | 343 passed |
| App Store Lite tests | 319 passed |
| Full tests with coverage | 343 passed; coverage report generated |
| Release keychain regression tests | 10 passed |
| Missing environment, absent path, relative path, invalid existing file | Bounded child XCTest processes passed; no default-store fallback |
| Locked fixture | Read/write failures return, failed checked/legacy saves preserve the original value |
| Interaction setting | Both initially enabled and disabled settings restored |
| User keychain preferences | Default and search list exactly match the before snapshot |
| Fixture residue in login keychain | No `com.zjah.NetBar.ci` item remains |

The first failing regression reproduced an important platform behavior:
`SecKeychainOpen` returned success for both an absent file and an invalid file;
`SecKeychainGetStatus` correctly returned -25294 and -25295 respectively. An add
against the absent-file handle fell back to the login keychain. The single
synthetic entry created by that probe was identified by exact service, account
and creation time, then removed by exact account/service. The corrected probes
complete without creating another entry there. Existing product credentials were
not read or modified. No login-keychain reset, unlock or ACL change was performed.

Rollback is a source revert of this repair; it requires no changes to keychain
preferences or existing credentials. The previously reported dialog is caused by
the test runner, so this repair does not require replacing the installed App.
