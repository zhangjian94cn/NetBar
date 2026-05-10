import XCTest
@testable import NetBar

final class EgressIPMonitorTests: XCTestCase {
    func testRefreshUsesCacheUntilForced() async {
        let keyBackup = Ping0KeyBackup()
        defer { keyBackup.restore() }

        let config = makeConfig()
        config.ping0APIKey = ""

        let client = StubIPClient()
        let monitor = EgressIPMonitor(config: config, client: client, minimumCacheTTL: 300)

        _ = await monitor.refreshNow(force: true)
        _ = await monitor.refreshNow(force: false)
        XCTAssertEqual(client.lookupCount, 1)

        _ = await monitor.refreshNow(force: true)
        XCTAssertEqual(client.lookupCount, 2)
    }

    func testDisabledConfigClearsStateAndDoesNotRequest() async {
        let keyBackup = Ping0KeyBackup()
        defer { keyBackup.restore() }

        let config = makeConfig()
        config.ipCheckEnabled = false
        config.ping0APIKey = ""

        let client = StubIPClient()
        let monitor = EgressIPMonitor(config: config, client: client, minimumCacheTTL: 300)

        let result = await monitor.refreshNow(force: true)

        XCTAssertNil(result)
        XCTAssertEqual(client.lookupCount, 0)
        let error = await MainActor.run { monitor.errorMessage }
        XCTAssertNil(error)
    }

    func testRefreshPassesVersionAndAPIKey() async {
        let keyBackup = Ping0KeyBackup()
        defer { keyBackup.restore() }

        let config = makeConfig()
        config.ipCheckVersion = .ipv6
        config.ping0APIKey = "secret"

        let client = StubIPClient()
        let monitor = EgressIPMonitor(config: config, client: client, minimumCacheTTL: 300)

        _ = await monitor.refreshNow(force: true)

        XCTAssertEqual(client.versions, [.ipv6])
        XCTAssertEqual(client.apiKeys, ["secret"])
    }

    func testRefreshStoresErrorMessage() async {
        let keyBackup = Ping0KeyBackup()
        defer { keyBackup.restore() }

        let config = makeConfig()
        config.ping0APIKey = ""

        let client = StubIPClient(error: EgressIPError.timeout)
        let monitor = EgressIPMonitor(config: config, client: client, minimumCacheTTL: 300)

        _ = await monitor.refreshNow(force: true)

        let error = await MainActor.run { monitor.errorMessage }
        XCTAssertEqual(error, "出口 IP 检测超时")
    }

    private func makeConfig() -> AppConfig {
        let suiteName = "NetBarEgressIPMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppConfig(defaults: defaults)
    }
}

private final class StubIPClient: IPIntelligenceClient {
    private(set) var lookupCount = 0
    private(set) var versions: [IPVersion] = []
    private(set) var apiKeys: [String?] = []
    private let result: EgressIPInfo
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
        self.result = EgressIPInfo(
            ip: "45.150.165.158",
            ipVersion: .ipv4,
            location: "美国 华盛顿州 西雅图",
            country: nil,
            province: nil,
            city: nil,
            asn: "AS201106",
            asnName: nil,
            org: "Spartan Host Ltd",
            isIDC: nil,
            ipRisk: nil,
            isNative: nil,
            asnType: nil,
            orgType: nil,
            source: "stub",
            fetchedAt: Date()
        )
    }

    func lookupCurrentIP(version: IPVersion, apiKey: String?) async throws -> EgressIPInfo {
        lookupCount += 1
        versions.append(version)
        apiKeys.append(apiKey)
        if let error {
            throw error
        }
        return result
    }

    func lookup(ip: String, apiKey: String) async throws -> EgressIPInfo {
        result
    }
}

private struct Ping0KeyBackup {
    private let previousValue: String?

    init() {
        previousValue = KeychainHelper.loadString(key: "ping0_api_key")
    }

    func restore() {
        if let previousValue {
            KeychainHelper.save(key: "ping0_api_key", value: previousValue)
        } else {
            KeychainHelper.delete(key: "ping0_api_key")
        }
    }
}
