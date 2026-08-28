import Foundation
import XCTest
@testable import NetBar

final class NetworkConnectivityTests: XCTestCase {
    func testCandidatePoolKeepsSavedVisibleNetworksButOnlyPinnedCandidateIsUsable() throws {
        let candidates = WiFiCandidateSelector.select(
            pinnedSSIDs: ["Office Backup", "Office Primary"],
            savedSSIDs: ["Office Primary", "Office Backup", "Historical", "Visible Saved"],
            visibleSignals: ["Office Primary": -62, "Office Backup": -48, "Visible Saved": -35, "Unknown": -20],
            currentSSID: "Office Primary",
            locationAccess: .allowed
        )

        XCTAssertEqual(candidates.map(\.displayName), ["Office Backup", "Office Primary", "Visible Saved"])
        XCTAssertFalse(candidates.contains(where: { $0.displayName == "Unknown" || $0.displayName == "Historical" }))
        XCTAssertEqual(WiFiCandidateSelector.bestUsableCandidate(from: candidates)?.displayName, "Office Primary")
    }

    func testDeniedLocationOnlyExposesCurrentSavedWiFi() {
        let candidates = WiFiCandidateSelector.select(
            pinnedSSIDs: ["Office Primary", "Office Backup"],
            savedSSIDs: ["Office Primary", "Office Backup"],
            visibleSignals: [:],
            currentSSID: "Office Backup",
            locationAccess: .denied
        )

        XCTAssertEqual(candidates.filter { $0.state != .unavailable }.map(\.displayName), ["Office Backup"])
    }

    func testRedactedCurrentSSIDStillAppearsAsAnonymousCandidate() {
        let candidates = WiFiCandidateSelector.select(
            pinnedSSIDs: [],
            savedSSIDs: ["Hidden by macOS"],
            visibleSignals: [:],
            currentSSID: nil,
            locationAccess: .denied,
            anonymousCurrentAssociated: true
        )

        XCTAssertEqual(candidates.map(\.id), [WiFiCandidateSelector.anonymousCurrentID])
        XCTAssertEqual(candidates.first?.displayName, "当前已连接 Wi-Fi")
        XCTAssertTrue(candidates.first?.isCurrent == true)
        XCTAssertEqual(WiFiCandidateSelector.bestUsableCandidate(from: candidates)?.id, WiFiCandidateSelector.anonymousCurrentID)
    }

    func testNoAnonymousCandidateWithoutAnActiveWiFiAddress() {
        let candidates = WiFiCandidateSelector.select(
            pinnedSSIDs: [],
            savedSSIDs: [],
            visibleSignals: [:],
            currentSSID: nil,
            locationAccess: .denied,
            anonymousCurrentAssociated: false
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testOpenVisibleNetworkIsNotAnAutomaticCandidate() {
        let candidates = WiFiCandidateSelector.select(
            pinnedSSIDs: ["Secured", "Open"],
            savedSSIDs: ["Secured", "Open"],
            visibleSignals: ["Secured": -60, "Open": -30],
            securedSSIDs: ["Secured"],
            currentSSID: nil,
            locationAccess: .allowed
        )

        XCTAssertEqual(candidates.first(where: { $0.displayName == "Secured" })?.state, .localOnly)
        XCTAssertEqual(candidates.first(where: { $0.displayName == "Open" })?.state, .unavailable)
    }

    func testCandidatePreferencePreservesOrderAndRemovesDuplicates() throws {
        let suite = "netbar-candidate-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = WiFiCandidatePreferenceStore(defaults: defaults)

        store.save(["B", "A", "B", ""])

        XCTAssertEqual(store.load(), ["B", "A"])
        XCTAssertTrue(store.isConfigured)
        defaults.removePersistentDomain(forName: suite)
    }

    func testAssociationArgumentsAreArrayBasedAndNeverContainPassword() {
        let arguments = LiveWiFiCandidateController.associationArguments(ssid: "Corp WiFi; $(whoami)")

        XCTAssertEqual(arguments, ["-setairportnetwork", "en0", "Corp WiFi; $(whoami)"])
        XCTAssertEqual(arguments.count, 3)
        XCTAssertFalse(arguments.contains(where: { $0.lowercased().contains("password") }))
    }

    func testFiveMinuteFallbackChangesToSixtySecondProbeCadence() {
        let start = Date(timeIntervalSince1970: 10_000)
        var state = NetworkRoutePolicyState(preference: .miniPreferred)
        state.beginWiFiFallback(at: start)

        XCTAssertEqual(state.phase, .temporaryWiFi)
        XCTAssertTrue(state.shouldRunSlowFallbackProbe(at: start.addingTimeInterval(299)))
        XCTAssertTrue(state.shouldRunSlowFallbackProbe(at: start.addingTimeInterval(300)))
        XCTAssertEqual(state.phase, .stableWiFiFallback)
        XCTAssertFalse(state.shouldRunSlowFallbackProbe(at: start.addingTimeInterval(350)))
        XCTAssertTrue(state.shouldRunSlowFallbackProbe(at: start.addingTimeInterval(360)))
    }

    func testMihomoWriteSurfaceOnlyClosesConnections() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("Sources/NetBar/Monitors/MihomoClient.swift"))

        XCTAssertTrue(source.contains("-X\", \"DELETE"))
        XCTAssertTrue(source.contains("/connections"))
        XCTAssertFalse(source.contains("/restart"))
        XCTAssertFalse(source.contains("/upgrade"))
        XCTAssertFalse(source.contains("PATCH\", \"/configs"))
        XCTAssertFalse(source.contains("PUT\", \"/configs"))
    }

    func testConnectivityProbeRejectsCaptiveRedirectAndAcceptsOneExactTarget() {
        let runner = ConnectivityCommandRunner()
        runner.curlStatuses = ["302", "204", "302", "204"]
        let prober = LiveConnectivityProber(runner: runner, mihomo: ConnectivityMihomo(controller: false, proxyReady: false))

        let result = prober.probe(interfaceName: "en0")

        XCTAssertTrue(result.directInternetReady)
        XCTAssertTrue(result.systemHTTPSReachable)
        XCTAssertTrue(runner.calls.filter { $0.0 == "/usr/bin/curl" }.allSatisfy { $0.1.contains("--max-redirs") })
    }

    func testManagedWiFiMayBeRoutedReadyWhileDirectHTTPSIsBlocked() {
        let result = ConnectivityProbeResult(
            interfaceName: "en0",
            carrierActive: true,
            ipv4Address: "192.168.219.173",
            gateway: "192.168.219.194",
            directHTTPSReachable: false,
            clashControllerReachable: true,
            clashHTTPSReachable: true,
            systemHTTPSReachable: true,
            physicalDefaultInterface: "en0"
        )

        XCTAssertFalse(result.directInternetReady)
        XCTAssertFalse(result.completeInternetReady)
        XCTAssertTrue(result.routedInternetReady)
    }

    func testEventLogHashesCandidateAndDropsEntriesOlderThanSevenDays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("network-events.jsonl")
        let old = "{\"timestamp\":\"2000-01-01T00:00:00Z\",\"event\":\"old\",\"detail\":\"expired\",\"candidate\":\"-\"}\n"
        try Data(old.utf8).write(to: file)
        let logger = NetworkEventLogger(fileURL: file)

        logger.record(event: "fallback", detail: "Corp Secret SSID selected", candidateSSID: "Corp Secret SSID")

        XCTAssertTrue(waitUntil {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("fallback")
        })
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(contents.contains("Corp Secret SSID"))
        XCTAssertFalse(contents.contains("expired"))
        XCTAssertTrue(contents.contains(WiFiCandidateSelector.candidateID(for: "Corp Secret SSID")))
    }

    func testEventLogSuppressesRepeatedIdenticalStateTransitions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-log-dedupe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("network-events.jsonl")
        let logger = NetworkEventLogger(fileURL: file)

        for _ in 0..<20 {
            logger.record(event: "wifi_fallback_started", detail: "雷雳未连接", candidateSSID: nil)
        }

        XCTAssertTrue(waitUntil {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("wifi_fallback_started")
        })
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.contains("wifi_fallback_started") }
        XCTAssertEqual(lines.count, 1)
    }

    private func waitUntil(timeout: TimeInterval = 1, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }
}

private final class ConnectivityMihomo: MihomoRouteRecovering {
    let controller: Bool
    let proxyReady: Bool

    init(controller: Bool, proxyReady: Bool) {
        self.controller = controller
        self.proxyReady = proxyReady
    }

    func isControllerAvailable() -> Bool { controller }
    func probeHTTPS() -> Bool { proxyReady }
    func closeAllConnections() -> Bool { false }
}

private final class ConnectivityCommandRunner: NetworkModeCommandRunning {
    var curlStatuses: [String] = []
    var calls: [(String, [String])] = []

    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        calls.append((executable, arguments))
        switch executable {
        case "/sbin/ifconfig":
            return .init(exitCode: 0, standardOutput: "inet 10.0.0.2 netmask 0xffffff00\nstatus: active\n", standardError: "")
        case "/sbin/route" where arguments.contains("-ifscope"):
            return .init(exitCode: 0, standardOutput: "gateway: 10.0.0.1\ninterface: en0\n", standardError: "")
        case "/sbin/route":
            return .init(exitCode: 0, standardOutput: "interface: en0\n", standardError: "")
        case "/usr/bin/curl":
            let status = curlStatuses.isEmpty ? "000" : curlStatuses.removeFirst()
            return .init(exitCode: status == "000" ? 1 : 0, standardOutput: status, standardError: "")
        default:
            return .init(exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
    }

    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "not used")
    }
}
