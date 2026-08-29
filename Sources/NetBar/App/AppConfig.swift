import Combine
import Foundation

enum VPSProviderType: String, Codable, CaseIterable {
    case threeXUI
}

/// 统一配置管理器 — 集中管理所有用户配置
/// 非敏感配置 → UserDefaults，敏感信息（密码/密钥）→ Keychain
final class AppConfig: ObservableObject {

    static let shared = AppConfig()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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

    // MARK: - 出口 IP 检测

    var ipCheckEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.ipCheckEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.ipCheckEnabled)
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.ipCheckEnabled)
        }
    }

    var ipCheckVersion: IPVersion {
        get {
            guard let rawValue = defaults.string(forKey: Keys.ipCheckVersion),
                  let version = IPVersion(rawValue: rawValue) else {
                return .auto
            }
            return version
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.ipCheckVersion)
        }
    }

    var ipCheckRefreshMinutes: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.ipCheckRefreshMinutes)
            return value > 0 ? max(5, value) : 5
        }
        set {
            objectWillChange.send()
            defaults.set(max(5, newValue), forKey: Keys.ipCheckRefreshMinutes)
        }
    }

    var hideWiFiName: Bool {
        get {
            guard defaults.object(forKey: Keys.hideWiFiName) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.hideWiFiName)
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.hideWiFiName)
        }
    }

    /// Read-only shadow run of `NetworkPolicyMachine`, off by default.
    ///
    /// The reducer only ever produces diagnostic proposals, and the takeover
    /// gate restarts its 24-hour observation window on any build that changes
    /// reducer effects. Leaving it on during unrelated iteration burns CPU and
    /// log volume for observations that will be discarded anyway, so observation
    /// is now something you opt into for the duration of a real window.
    var networkPolicyShadowEnabled: Bool {
        get {
            if ProcessInfo.processInfo.environment["NETBAR_POLICY_SHADOW"] == "1" {
                return true
            }
            return defaults.bool(forKey: Keys.networkPolicyShadowEnabled)
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.networkPolicyShadowEnabled)
        }
    }

    var ping0APIKey: String {
        get { KeychainHelper.loadString(key: Keys.ping0APIKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainHelper.delete(key: Keys.ping0APIKey)
            } else {
                KeychainHelper.save(key: Keys.ping0APIKey, value: trimmed)
            }
        }
    }

    // MARK: - VPS 配置

    struct VPSConfig: Codable, Identifiable {
        var id: String
        var name: String
        var provider: VPSProviderType
        var host: String
        var port: Int
        var basePath: String
        var username: String
        var useTLS: Bool
        var allowSelfSignedCertificate: Bool

        init(
            id: String = UUID().uuidString,
            name: String,
            provider: VPSProviderType = .threeXUI,
            host: String,
            port: Int,
            basePath: String,
            username: String,
            useTLS: Bool,
            allowSelfSignedCertificate: Bool = false
        ) {
            self.id = id
            self.name = name
            self.provider = provider
            self.host = host
            self.port = port
            self.basePath = basePath
            self.username = username
            self.useTLS = useTLS
            self.allowSelfSignedCertificate = allowSelfSignedCertificate
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case provider
            case host
            case port
            case basePath
            case username
            case useTLS
            case allowSelfSignedCertificate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try container.decode(String.self, forKey: .name)
            provider = try container.decodeIfPresent(VPSProviderType.self, forKey: .provider) ?? .threeXUI
            host = try container.decode(String.self, forKey: .host)
            port = try container.decode(Int.self, forKey: .port)
            basePath = try container.decodeIfPresent(String.self, forKey: .basePath) ?? ""
            username = try container.decode(String.self, forKey: .username)
            useTLS = try container.decode(Bool.self, forKey: .useTLS)
            allowSelfSignedCertificate = try container.decodeIfPresent(Bool.self, forKey: .allowSelfSignedCertificate) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(provider, forKey: .provider)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
            try container.encode(basePath, forKey: .basePath)
            try container.encode(username, forKey: .username)
            try container.encode(useTLS, forKey: .useTLS)
            try container.encode(allowSelfSignedCertificate, forKey: .allowSelfSignedCertificate)
        }

        static func passwordKey(for id: String) -> String {
            "vps_password_\(id)"
        }

        var panelURL: String {
            var components = URLComponents()
            components.scheme = useTLS ? "https" : "http"
            components.host = host
            components.port = port
            let normalizedPath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = normalizedPath.isEmpty ? "" : "/\(normalizedPath)"
            return components.url?.absoluteString ?? "\(useTLS ? "https" : "http")://\(host):\(port)"
        }

        /// 密码从 Keychain 读取，不参与 Codable
        var password: String {
            get { KeychainHelper.loadString(key: Self.passwordKey(for: id)) ?? "" }
            nonmutating set { KeychainHelper.save(key: Self.passwordKey(for: id), value: newValue) }
        }
    }

    var vpsConfigs: [VPSConfig] {
        get {
            guard let configs = decodeStoredVPSConfigs() else {
                return migrateLegacyVPSConfigIfNeeded()
            }
            return configs
        }
        set {
            saveVPSConfigs(newValue)
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

    var selectedPopoverSection: PopoverSection {
        get {
            PopoverSection.resolve(
                storedValue: defaults.string(forKey: Keys.selectedPopoverSection),
                flavor: DistributionFlavor.current
            )
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.selectedPopoverSection)
        }
    }

    // MARK: - Legacy Migration

    private func decodeStoredVPSConfigs() -> [VPSConfig]? {
        guard let data = defaults.data(forKey: Keys.vpsConfigs) else {
            return nil
        }
        return try? JSONDecoder().decode([VPSConfig].self, from: data)
    }

    /// 一次性迁移旧版 UserDefaults 配置。商业版新安装不再使用 .env / vps_bwg_* 作为配置入口。
    private func migrateLegacyVPSConfigIfNeeded() -> [VPSConfig] {
        guard let config = makeLegacyVPSConfig() else { return [] }
        saveVPSConfigs([config])
        Log.config.info("已将 legacy VPS 配置迁移到应用内服务器配置")
        return [config]
    }

    private func makeLegacyVPSConfig() -> VPSConfig? {
        guard let host = defaults.string(forKey: "vps_bwg_host"),
              let username = defaults.string(forKey: "vps_bwg_user") else {
            return nil
        }

        let port = defaults.integer(forKey: "vps_bwg_port") != 0
            ? defaults.integer(forKey: "vps_bwg_port") : 2053
        let basePath = defaults.string(forKey: "vps_bwg_path") ?? ""

        let config = VPSConfig(
            id: UUID().uuidString,
            name: "BWG-CN2GIA",
            provider: .threeXUI,
            host: host,
            port: port,
            basePath: basePath,
            username: username,
            useTLS: true,
            allowSelfSignedCertificate: true
        )
        let legacyPassword = defaults.string(forKey: "vps_bwg_pass") ?? ""
        if !legacyPassword.isEmpty {
            config.password = legacyPassword
            Log.config.info("VPS 密码已从 legacy UserDefaults 迁移到 Keychain")
        }
        return config
    }

    private func saveVPSConfigs(_ configs: [VPSConfig]) {
        let existingIDs = Set(decodeStoredVPSConfigs()?.map(\.id) ?? [])
        let nextIDs = Set(configs.map(\.id))
        existingIDs.subtracting(nextIDs).forEach { id in
            KeychainHelper.delete(key: VPSConfig.passwordKey(for: id))
        }

        let data = try? JSONEncoder().encode(configs)
        defaults.set(data, forKey: Keys.vpsConfigs)
        clearLegacyVPSDefaults()
    }

    private func clearLegacyVPSDefaults() {
        defaults.removeObject(forKey: "vps_bwg_name")
        defaults.removeObject(forKey: "vps_bwg_host")
        defaults.removeObject(forKey: "vps_bwg_port")
        defaults.removeObject(forKey: "vps_bwg_path")
        defaults.removeObject(forKey: "vps_bwg_user")
        defaults.removeObject(forKey: "vps_bwg_pass")
        defaults.removeObject(forKey: "vps_bwg_use_tls")
    }

    // MARK: - Keys

    private enum Keys {
        static let mihomoSocketPath = "mihomo_socket_path"
        static let mihomoControllerURL = "mihomo_controller_url"
        static let mihomoSecret = "mihomo_secret"
        static let ipCheckEnabled = "ip_check_enabled"
        static let ipCheckVersion = "ip_check_version"
        static let ipCheckRefreshMinutes = "ip_check_refresh_minutes"
        static let hideWiFiName = "hide_wifi_name"
        static let ping0APIKey = "ping0_api_key"
        static let vpsConfigs = "vps_configs_v2"
        static let refreshInterval = "refresh_interval"
        static let selectedPopoverSection = "popover_selected_section_v1"
        static let networkPolicyShadowEnabled = "network_policy_shadow_enabled"
    }
}
