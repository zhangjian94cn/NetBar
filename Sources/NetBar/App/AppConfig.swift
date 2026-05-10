import Foundation

/// 统一配置管理器 — 集中管理所有用户配置
/// 非敏感配置 → UserDefaults，敏感信息（密码/密钥）→ Keychain
final class AppConfig: ObservableObject {

    static let shared = AppConfig()

    private let defaults = UserDefaults.standard

    // MARK: - Mihomo 代理配置

    var mihomoSocketPath: String {
        get { defaults.string(forKey: Keys.mihomoSocketPath) ?? "/tmp/verge/verge-mihomo.sock" }
        set { defaults.set(newValue, forKey: Keys.mihomoSocketPath) }
    }

    var mihomoControllerURL: String {
        get { defaults.string(forKey: Keys.mihomoControllerURL) ?? "http://127.0.0.1:9097/connections" }
        set { defaults.set(newValue, forKey: Keys.mihomoControllerURL) }
    }

    var mihomoSecret: String {
        get { KeychainHelper.loadString(key: Keys.mihomoSecret) ?? "" }
        set { KeychainHelper.save(key: Keys.mihomoSecret, value: newValue) }
    }

    // MARK: - VPS 配置

    struct VPSConfig: Codable, Identifiable {
        var id: String
        var name: String
        var host: String
        var port: Int
        var basePath: String
        var username: String
        var useTLS: Bool

        /// 密码从 Keychain 读取，不参与 Codable
        var password: String {
            get { KeychainHelper.loadString(key: "vps_password_\(id)") ?? "" }
            nonmutating set { KeychainHelper.save(key: "vps_password_\(id)", value: newValue) }
        }
    }

    var vpsConfigs: [VPSConfig] {
        get {
            guard let data = defaults.data(forKey: Keys.vpsConfigs) else {
                return loadLegacyVPSConfig()
            }
            return (try? JSONDecoder().decode([VPSConfig].self, from: data)) ?? []
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Keys.vpsConfigs)
            objectWillChange.send()
        }
    }

    // MARK: - 通用设置

    var refreshInterval: TimeInterval {
        get {
            let val = defaults.double(forKey: Keys.refreshInterval)
            return val > 0 ? val : 2.0
        }
        set { defaults.set(newValue, forKey: Keys.refreshInterval) }
    }

    // MARK: - Legacy Migration

    /// 从旧版 UserDefaults 格式迁移 VPS 配置（兼容 install.sh 写入的格式）
    private func loadLegacyVPSConfig() -> [VPSConfig] {
        guard let host = defaults.string(forKey: "vps_bwg_host"),
              let username = defaults.string(forKey: "vps_bwg_user") else {
            return []
        }

        let port = defaults.integer(forKey: "vps_bwg_port") != 0
            ? defaults.integer(forKey: "vps_bwg_port") : 2053
        let basePath = defaults.string(forKey: "vps_bwg_path") ?? ""

        // 从旧 UserDefaults 读取密码并迁移到 Keychain
        let legacyPassword = defaults.string(forKey: "vps_bwg_pass") ?? ""

        let config = VPSConfig(
            id: "bwg-cn2gia",
            name: "BWG-CN2GIA",
            host: host,
            port: port,
            basePath: basePath,
            username: username,
            useTLS: true
        )

        if !legacyPassword.isEmpty {
            config.password = legacyPassword
            // 迁移后清除明文密码
            defaults.removeObject(forKey: "vps_bwg_pass")
            Log.config.info("VPS 密码已从 UserDefaults 迁移到 Keychain")
        }

        // 持久化新格式
        let configs = [config]
        vpsConfigs = configs

        return configs
    }

    // MARK: - Keys

    private enum Keys {
        static let mihomoSocketPath = "mihomo_socket_path"
        static let mihomoControllerURL = "mihomo_controller_url"
        static let mihomoSecret = "mihomo_secret"
        static let vpsConfigs = "vps_configs_v2"
        static let refreshInterval = "refresh_interval"
    }
}
