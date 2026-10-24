import Foundation
import Security

/// Noninteractive credential storage. Background work must never open a system dialog.
enum KeychainHelper {
    private static let accessLock = NSLock()

    struct StorageError: LocalizedError {
        let status: OSStatus
        var context: String? = nil

        var errorDescription: String? {
            context ?? "钥匙串已锁定或当前应用无权访问（\(status)）。请在“钥匙串访问”检查记录后重试；原记录保持不变。"
        }
    }

    // kSecUseAuthenticationUIFail alone does not suppress every legacy keychain
    // dialog. Serialize ALL of our operations while changing the process setting.
    private static func noninteractive<T>(_ operation: () throws -> T) throws -> T {
        accessLock.lock()
        defer { accessLock.unlock() }
        var allowed = DarwinBoolean(true)
        let previous = SecKeychainGetUserInteractionAllowed(&allowed)
        guard previous == errSecSuccess else { throw StorageError(status: previous) }
        let disabled = SecKeychainSetUserInteractionAllowed(false)
        guard disabled == errSecSuccess else { throw StorageError(status: disabled) }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try operation()
    }

    private static func scoped(_ query: [String: Any], adding: Bool = false) throws -> [String: Any] {
        var result = query
        result[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let isTestProcess = NSClassFromString("XCTestCase") != nil
        #if !DEBUG
        // Installed release apps ignore the fixture environment. Release XCTest
        // processes still need the same isolation as debug tests.
        if !isTestProcess { return result }
        #endif
        // Even a direct `swift test` must fail closed instead of using personal
        // credentials. The supported test commands create the disposable store.
        guard let path = ProcessInfo.processInfo.environment["NETBAR_CI_KEYCHAIN"] else {
            if isTestProcess {
                throw StorageError(status: errSecNotAvailable,
                    context: "Tests require a fixture keychain. Run bash scripts/ci-checks.sh direct-tests (or lite-tests / coverage).")
            }
            return result
        }
        guard path.hasPrefix("/") else {
            throw StorageError(status: errSecParam, context: "The fixture keychain path must be absolute.")
        }
        // SecKeychainOpen can succeed for a nonexistent path, and SecItemAdd can
        // then silently fall back to the default keychain. Check the real store.
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw StorageError(status: errSecNoSuchKeychain,
                context: "The fixture keychain does not exist; personal keychains will not be used.")
        }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw StorageError(status: status == errSecSuccess ? errSecNotAvailable : status,
                context: "The fixture keychain is unavailable; personal keychains will not be used.")
        }
        var keychainStatus: SecKeychainStatus = 0
        let checked = SecKeychainGetStatus(keychain, &keychainStatus)
        guard checked == errSecSuccess else { throw StorageError(status: checked) }
        result[kSecAttrService as String] = "com.zjah.NetBar.ci"
        if adding { result[kSecUseKeychain as String] = keychain }
        else { result[kSecMatchSearchList as String] = [keychain] }
        return result
    }

    private static var service: String {
        #if DEBUG
        if MonitorCoordinator.isVisualCaptureRun { return Bundle.main.bundleIdentifier ?? "com.zjah.NetBar.preview" }
        #endif
        return "com.zjah.NetBar"
    }

    private static func query(key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    static func readChecked(key: String) throws -> Data? {
        try noninteractive {
            var query = query(key: key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: AnyObject?
            let status = SecItemCopyMatching(try scoped(query) as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw StorageError(status: status) }
            guard let data = value as? Data else { throw StorageError(status: errSecDecode) }
            return data
        }
    }

    /// Update in place. A denied/locked write must preserve the existing item.
    static func writeChecked(key: String, data: Data) throws {
        try noninteractive {
            let query = query(key: key)
            let status = SecItemUpdate(try scoped(query) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw StorageError(status: status) }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(try scoped(add, adding: true) as CFDictionary, nil)
            guard added == errSecSuccess else { throw StorageError(status: added) }
        }
    }

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        save(key: key, data: data)
    }

    static func save(key: String, data: Data) {
        do { try writeChecked(key: key, data: data) }
        catch { Log.config.error("Keychain save failed for key '\(key)': \(error.localizedDescription)") }
    }

    static func loadString(key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func load(key: String) -> Data? {
        try? readChecked(key: key)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        (try? noninteractive {
            SecItemDelete(try scoped(query(key: key)) as CFDictionary) == errSecSuccess
        }) ?? false
    }
}
