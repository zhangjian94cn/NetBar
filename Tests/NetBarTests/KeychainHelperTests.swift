import XCTest
import Security
@testable import NetBar

final class KeychainHelperTests: XCTestCase {

    private let testKey = "com.zjah.NetBar.test_key_\(UUID().uuidString)"

    override func tearDown() {
        super.tearDown()
        KeychainHelper.delete(key: testKey)
    }

    func testSaveAndLoadString() {
        KeychainHelper.save(key: testKey, value: "test_secret_123")
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, "test_secret_123")
    }

    func testLoadNonexistentKey() {
        let loaded = KeychainHelper.loadString(key: "nonexistent_key_\(UUID().uuidString)")
        XCTAssertNil(loaded)
    }

    func testUpsertOverwritesValue() {
        KeychainHelper.save(key: testKey, value: "first_value")
        KeychainHelper.save(key: testKey, value: "second_value")
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, "second_value")
    }

    func testDeleteRemovesValue() {
        KeychainHelper.save(key: testKey, value: "to_delete")
        let deleted = KeychainHelper.delete(key: testKey)
        XCTAssertTrue(deleted)
        XCTAssertNil(KeychainHelper.loadString(key: testKey))
    }

    func testSaveAndLoadEmptyString() {
        KeychainHelper.save(key: testKey, value: "")
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, "")
    }

    func testSaveAndLoadUnicodeString() {
        let unicode = "密码🔑测试"
        KeychainHelper.save(key: testKey, value: unicode)
        let loaded = KeychainHelper.loadString(key: testKey)
        XCTAssertEqual(loaded, unicode)
    }

    private func fixtureKeychain() throws -> SecKeychain {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NETBAR_CI_KEYCHAIN"])
        var keychain: SecKeychain?
        XCTAssertEqual(SecKeychainOpen(path, &keychain), errSecSuccess)
        return try XCTUnwrap(keychain)
    }

    func testWritesAreScopedToFixtureKeychain() throws {
        let keychain = try fixtureKeychain()
        try KeychainHelper.writeChecked(key: testKey, data: Data("fixture-only".utf8))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.zjah.NetBar.ci",
            kSecAttrAccount as String: testKey,
            kSecMatchSearchList as String: [keychain],
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, Data("fixture-only".utf8))
    }

    func testLockedFixtureFailsWithoutLosingValue() throws {
        let keychain = try fixtureKeychain()
        try KeychainHelper.writeChecked(key: testKey, data: Data("original".utf8))
        XCTAssertEqual(SecKeychainLock(keychain), errSecSuccess)
        // The CI fixture has an empty password inside a private temporary directory.
        func unlock() -> OSStatus {
            "".withCString { SecKeychainUnlock(keychain, 0, $0, true) }
        }
        defer { _ = unlock() }
        XCTAssertThrowsError(try KeychainHelper.readChecked(key: testKey))
        XCTAssertThrowsError(try KeychainHelper.writeChecked(key: testKey, data: Data("replacement".utf8)))
        KeychainHelper.save(key: testKey, value: "legacy-replacement")
        XCTAssertNil(KeychainHelper.load(key: testKey))
        XCTAssertEqual(unlock(), errSecSuccess)
        XCTAssertEqual(try KeychainHelper.readChecked(key: testKey), Data("original".utf8))
    }

    func testOperationsRestoreInteractionSetting() throws {
        var original = DarwinBoolean(true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        for allowed in [false, true] {
            XCTAssertEqual(SecKeychainSetUserInteractionAllowed(allowed), errSecSuccess)
            defer { SecKeychainSetUserInteractionAllowed(original.boolValue) }
            KeychainHelper.save(key: testKey, value: "fixture")
            _ = KeychainHelper.load(key: testKey)
            _ = KeychainHelper.delete(key: testKey)
            var restored = DarwinBoolean(!allowed)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
            XCTAssertEqual(restored.boolValue, allowed)
        }
    }

    func testUnavailableFixtureFailsClosed() throws {
        if let probe = ProcessInfo.processInfo.environment["NETBAR_KEYCHAIN_FAILURE_PROBE"] {
            XCTAssertNotNil(NSClassFromString("XCTestCase"))
            for operation in [
                { _ = try KeychainHelper.readChecked(key: self.testKey) },
                { try KeychainHelper.writeChecked(key: self.testKey, data: Data("fixture".utf8)) },
            ] {
                XCTAssertThrowsError(try operation()) { error in
                    guard let storage = error as? KeychainHelper.StorageError else {
                        return XCTFail("Expected a storage error, got \(error)")
                    }
                    XCTAssertNotEqual(storage.status, errSecSuccess)
                    if probe == "missing" { XCTAssertEqual(storage.status, errSecNotAvailable) }
                }
            }
            KeychainHelper.save(key: testKey, value: "must-not-be-saved")
            XCTAssertNil(KeychainHelper.load(key: testKey))
            XCTAssertFalse(KeychainHelper.delete(key: testKey))
            var allowed = DarwinBoolean(false)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertTrue(allowed.boolValue)
            return
        }

        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-keychain-probes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDirectory) }
        let invalidFile = probeDirectory.appendingPathComponent("invalid.keychain-db")
        try Data("not a keychain".utf8).write(to: invalidFile)
        for probe in ["missing", "unavailable", "relative", "invalid-file"] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["-XCTest", "NetBarTests.KeychainHelperTests/testUnavailableFixtureFailsClosed",
                                 Bundle(for: KeychainHelperTests.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment["NETBAR_KEYCHAIN_FAILURE_PROBE"] = probe
            switch probe {
            case "missing": environment.removeValue(forKey: "NETBAR_CI_KEYCHAIN")
            case "relative": environment["NETBAR_CI_KEYCHAIN"] = "relative.keychain-db"
            case "invalid-file": environment["NETBAR_CI_KEYCHAIN"] = invalidFile.path
            default:
                environment["NETBAR_CI_KEYCHAIN"] = probeDirectory.appendingPathComponent("missing.keychain-db").path
            }
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            let completed = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completed.signal() }
            try process.run()
            guard completed.wait(timeout: .now() + 15) == .success else {
                process.terminate()
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return XCTFail("Keychain \(probe) probe did not return within 15 seconds")
            }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, "Keychain \(probe) probe failed:\n\(text)")
            XCTAssertTrue(text.contains("Executed 1 test"), "The child must execute the regression: \(text)")
        }
    }
}
