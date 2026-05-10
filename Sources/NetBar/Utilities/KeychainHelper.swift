import Foundation
import Security

/// 轻量 Keychain 封装 — 安全存储密码和密钥
/// 不引入第三方依赖，直接使用 Security.framework
enum KeychainHelper {

    private static let service = "com.zjah.NetBar"

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
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Log.config.error("Keychain save failed for key '\(key)': \(status)")
        }
    }

    /// 从 Keychain 读取 Data
    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
