import Foundation
import Security

/// 轻量 Keychain 封装 — 安全存储密码和密钥
/// 不引入第三方依赖，直接使用 Security.framework
enum KeychainHelper {
    private static let checkedAccessLock = NSLock()

    // Native CI must never read or prompt for the user's login keychain.
    // Release builds ignore this test-only environment entirely.
    private static func scoped(_ query: [String: Any], adding: Bool = false) -> [String: Any] {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["NETBAR_CI_KEYCHAIN"] {
            var keychain: SecKeychain?
            guard path.hasPrefix("/"), SecKeychainOpen(path, &keychain) == errSecSuccess,
                  let keychain else { preconditionFailure("CI keychain is unavailable") }
            var result = query
            result[kSecAttrService as String] = "com.zjah.NetBar.ci"
            if adding { result[kSecUseKeychain as String] = keychain }
            else { result[kSecMatchSearchList as String] = [keychain] }
            result[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            return result
        }
        #endif
        return query
    }


    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "钥匙串已锁定或当前应用无权访问（\(status)）。请在“钥匙串访问”检查记录后重试；原记录保持不变。" }
    }

    /// Checked operations for explicit credential editing. Never delete before an update.
    static func readChecked(key: String) throws -> Data? {
        // Legacy login-keychain ACLs can ignore kSecUseAuthenticationUIFail.
        // Keep this explicit operation noninteractive as well, restoring the
        // process setting immediately afterwards; do not alter keychain ACLs.
        checkedAccessLock.lock(); defer { checkedAccessLock.unlock() }
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var value: AnyObject?
        let status = SecItemCopyMatching(scoped(query) as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw StorageError(status: status) }
        return data
    }

    static func writeChecked(key: String, data: Data) throws {
        checkedAccessLock.lock(); defer { checkedAccessLock.unlock() }
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        let status = SecItemUpdate(scoped(query) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StorageError(status: status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(scoped(add, adding: true) as CFDictionary, nil)
        guard added == errSecSuccess else { throw StorageError(status: added) }
    }

    private static var service: String {
        #if DEBUG
        if MonitorCoordinator.isVisualCaptureRun { return Bundle.main.bundleIdentifier ?? "com.zjah.NetBar.preview" }
        #endif
        return "com.zjah.NetBar"
    }

    /// 保存字符串到 Keychain
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        save(key: key, data: data)
    }

    /// 从 Keychain 读取字符串
    static func loadString(key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 保存 Data 到 Keychain
    static func save(key: String, data: Data) {
        // 先删除旧值（upsert 模式）
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(scoped(deleteQuery) as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(scoped(addQuery, adding: true) as CFDictionary, nil)
        if status != errSecSuccess {
            Log.config.error("Keychain save failed for key '\(key)': \(status)")
        }
    }

    /// 从 Keychain 读取 Data
    static func load(key: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        #if DEBUG
        // Rebuilt QA bundles must never wait for authorization of an older
        // preview signature. Missing fixture credentials stay an explicit error.
        if MonitorCoordinator.isVisualCaptureRun {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching(scoped(query) as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// 删除 Keychain 条目
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(scoped(query) as CFDictionary) == errSecSuccess
    }
}
