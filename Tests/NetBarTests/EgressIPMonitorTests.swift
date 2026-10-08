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
            locationRaw: "美国 华盛顿州 西雅图",
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

extension EgressIPMonitorTests {
    @MainActor
    func testConcurrentRefreshesShareOneLookup() async {
        let client = SuspendedIPClient()
        let monitor = EgressIPMonitor(config: makeConfig(), client: client)
        let first = Task { await monitor.refreshNow(force: true) }
        await fulfillment(of: [client.entered], timeout: 2)
        let second = Task { await monitor.refreshNow(force: true) }
        for _ in 0..<20 { await Task.yield() }
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
        await client.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult?.ip, secondResult?.ip)
        XCTAssertNotNil(firstResult)
        XCTAssertFalse(monitor.isLoading)
    }

    @MainActor
    func testStoppedLookupCannotPublishEvenIfClientIgnoresCancellation() async {
        let client = SuspendedIPClient()
        let monitor = EgressIPMonitor(config: makeConfig(), client: client)
        let first = Task { await monitor.refreshNow(force: true) }
        await fulfillment(of: [client.entered], timeout: 2)
        monitor.stop()
        await client.release()
        let result = await first.value
        XCTAssertNil(result)
        XCTAssertNil(monitor.info)
        XCTAssertNil(monitor.errorMessage)
        XCTAssertFalse(monitor.isLoading)
    }

    @MainActor
    func testNewGenerationIsNotClearedByLateOldCompletion() async {
        let client = SuspendedIPClient()
        let monitor = EgressIPMonitor(config: makeConfig(), client: client)
        let first = Task { await monitor.refreshNow(force: true) }
        await fulfillment(of: [client.entered], timeout: 2)
        monitor.stop()
        let second = Task { await monitor.refreshNow(force: true) }
        await fulfillment(of: [client.secondEntered], timeout: 2)
        await client.release()
        _ = await first.value
        XCTAssertTrue(monitor.isLoading, "Old completion must not clear the new generation")
        XCTAssertNil(monitor.info)
        await client.release()
        let result = await second.value
        XCTAssertNotNil(result)
        XCTAssertEqual(monitor.info?.ip, result?.ip)
        XCTAssertFalse(monitor.isLoading)
    }

    @MainActor
    func testDisableCancelsLookupAndClearsState() async {
        let config = makeConfig()
        let client = SuspendedIPClient()
        let monitor = EgressIPMonitor(config: config, client: client)
        let first = Task { await monitor.refreshNow(force: true) }
        await fulfillment(of: [client.entered], timeout: 2)
        config.ipCheckEnabled = false
        monitor.reloadSettingsAndRefresh()
        await client.release()
        _ = await first.value
        XCTAssertNil(monitor.info)
        XCTAssertFalse(monitor.isLoading)
    }

    func testCancellationDoesNotStartFallbackLookup() async {
        let fallback = StubIPClient()
        let router = EgressIPClientRouter(apiClient: fallback, webClient: CancelledIPClient())
        do {
            _ = try await router.lookupCurrentIP(version: .auto, apiKey: nil)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fallback.lookupCount, 0)
    }
}

private actor SuspendedIPClient: IPIntelligenceClient {
    nonisolated let entered = XCTestExpectation(description: "lookup entered")
    private(set) var calls = 0
    nonisolated let secondEntered = XCTestExpectation(description: "second lookup entered")
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func lookupCurrentIP(version: IPVersion, apiKey: String?) async throws -> EgressIPInfo {
        calls += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            if calls == 1 { entered.fulfill() } else { secondEntered.fulfill() }
        }
        return try await StubIPClient().lookupCurrentIP(version: version, apiKey: apiKey)
    }
    func release() { if !continuations.isEmpty { continuations.removeFirst().resume() } }
    func lookup(ip: String, apiKey: String) async throws -> EgressIPInfo {
        try await lookupCurrentIP(version: .auto, apiKey: apiKey)
    }
}

private struct CancelledIPClient: IPIntelligenceClient {
    func lookupCurrentIP(version: IPVersion, apiKey: String?) async throws -> EgressIPInfo { throw CancellationError() }
    func lookup(ip: String, apiKey: String) async throws -> EgressIPInfo { throw CancellationError() }
}
