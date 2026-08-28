import XCTest
@testable import NetBar

final class AppConfigTests: XCTestCase {
    func testV2SchemaDefaultsProviderAndCertificateFlag() throws {
        let defaults = makeDefaults()
        let legacyV2JSON = """
        [{"id":"old","name":"Old","host":"example.com","port":2053,"basePath":"xui","username":"u","useTLS":true}]
        """
        defaults.set(Data(legacyV2JSON.utf8), forKey: "vps_configs_v2")

        let configs = AppConfig(defaults: defaults).vpsConfigs

        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].provider, .threeXUI)
        XCTAssertFalse(configs[0].allowSelfSignedCertificate)
    }

    func testDeletingVPSConfigDeletesPasswordKey() {
        let defaults = makeDefaults()
        let configStore = AppConfig(defaults: defaults)
        let id = "test-delete-\(UUID().uuidString)"
        let server = AppConfig.VPSConfig(
            id: id,
            name: "Delete Test",
            provider: .threeXUI,
            host: "example.com",
            port: 443,
            basePath: "",
            username: "u",
            useTLS: true,
            allowSelfSignedCertificate: false
        )
        server.password = "secret"

        configStore.vpsConfigs = [server]
        XCTAssertEqual(KeychainHelper.loadString(key: AppConfig.VPSConfig.passwordKey(for: id)), "secret")

        configStore.vpsConfigs = []
        XCTAssertNil(KeychainHelper.loadString(key: AppConfig.VPSConfig.passwordKey(for: id)))
    }

    func testLegacyVPSMigrationIsOneTimeAndKeepsSelfSignedCompatibility() {
        let defaults = makeDefaults()
        defaults.set("legacy.example.com", forKey: "vps_bwg_host")
        defaults.set(2053, forKey: "vps_bwg_port")
        defaults.set("xui", forKey: "vps_bwg_path")
        defaults.set("legacy-user", forKey: "vps_bwg_user")
        defaults.set("legacy-pass", forKey: "vps_bwg_pass")

        let configs = AppConfig(defaults: defaults).vpsConfigs

        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].host, "legacy.example.com")
        XCTAssertTrue(configs[0].allowSelfSignedCertificate)
        XCTAssertEqual(configs[0].password, "legacy-pass")
        XCTAssertNil(defaults.string(forKey: "vps_bwg_host"))
        XCTAssertNil(defaults.string(forKey: "vps_bwg_pass"))

        KeychainHelper.delete(key: AppConfig.VPSConfig.passwordKey(for: configs[0].id))
    }

    func testIPCheckDefaultsAndVersionStorage() {
        let defaults = makeDefaults()
        let configStore = AppConfig(defaults: defaults)

        XCTAssertTrue(configStore.ipCheckEnabled)
        XCTAssertEqual(configStore.ipCheckVersion, .auto)
        XCTAssertEqual(configStore.ipCheckRefreshMinutes, 5)
        XCTAssertTrue(configStore.hideWiFiName)

        configStore.ipCheckEnabled = false
        configStore.ipCheckVersion = .ipv6
        configStore.ipCheckRefreshMinutes = 15
        configStore.hideWiFiName = false

        XCTAssertFalse(configStore.ipCheckEnabled)
        XCTAssertEqual(configStore.ipCheckVersion, .ipv6)
        XCTAssertEqual(configStore.ipCheckRefreshMinutes, 15)
        XCTAssertFalse(configStore.hideWiFiName)
    }

    func testPing0APIKeyStoresAndClearsKeychainValue() {
        let previousValue = KeychainHelper.loadString(key: "ping0_api_key")
        defer {
            if let previousValue {
                KeychainHelper.save(key: "ping0_api_key", value: previousValue)
            } else {
                KeychainHelper.delete(key: "ping0_api_key")
            }
        }

        let configStore = AppConfig(defaults: makeDefaults())
        configStore.ping0APIKey = "  test-key  "
        XCTAssertEqual(configStore.ping0APIKey, "test-key")

        configStore.ping0APIKey = ""
        XCTAssertEqual(configStore.ping0APIKey, "")
    }

    func testPopoverSelectionPersistsWithinCurrentDistributionFlavor() {
        let defaults = makeDefaults()
        let configStore = AppConfig(defaults: defaults)
        let expected: PopoverSection = DistributionFlavor.current == .directFull ? .applications : .monitoring

        configStore.selectedPopoverSection = expected

        XCTAssertEqual(AppConfig(defaults: defaults).selectedPopoverSection, expected)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "NetBarTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
