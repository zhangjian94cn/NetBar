import Foundation
import XCTest
@testable import NetBar

final class NetworkRoutePolicyTests: XCTestCase {
    func testPreferenceDefaultsToMiniAndManualWiFiSelectionPersists() throws {
        let suite = "netbar-policy-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let provider = PolicySnapshotProvider()
        let routeSafety = PolicyRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: defaults
        )

        XCTAssertEqual(controller.routePreference, .miniPreferred)
        controller.switchMode(to: .localWiFi)
        XCTAssertEqual(controller.routePreference, .localWiFi)

        let reloaded = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: defaults
        )
        XCTAssertEqual(reloaded.routePreference, .localWiFi)
        defaults.removePersistentDomain(forName: suite)
    }

    func testMiniPreferredIsDefaultAndStabilityRequiresThirtySeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = NetworkRoutePolicyState(preference: .miniPreferred)

        state.recordHealthy(at: start)

        XCTAssertEqual(state.stableDuration(at: start.addingTimeInterval(29)), 29)
        XCTAssertEqual(state.stableDuration(at: start.addingTimeInterval(30)), 30)
        state.recordFailure()
        XCTAssertEqual(state.stableDuration(at: start.addingTimeInterval(31)), 0)
        XCTAssertEqual(state.consecutiveFailures, 1)
    }

    func testTwoFailedAutomaticReturnsWithinTenMinutesOpenCircuitForTenMinutes() {
        let start = Date(timeIntervalSince1970: 2_000)
        var state = NetworkRoutePolicyState(preference: .miniPreferred)

        state.recordAutomaticFallback(at: start)
        XCTAssertTrue(state.automaticFallbacks.isEmpty, "首次降级前没有自动切回，不应计入抖动")
        state.recordAutomaticReturn(at: start.addingTimeInterval(60))
        state.recordAutomaticFallback(at: start.addingTimeInterval(120))
        XCTAssertNil(state.circuitBreakerUntil)
        state.recordAutomaticReturn(at: start.addingTimeInterval(240))
        state.recordAutomaticFallback(at: start.addingTimeInterval(300))

        XCTAssertEqual(state.circuitBreakerUntil, start.addingTimeInterval(900))
        state.clearExpiredCircuitBreaker(at: start.addingTimeInterval(899))
        XCTAssertNotNil(state.circuitBreakerUntil)
        state.clearExpiredCircuitBreaker(at: start.addingTimeInterval(900))
        XCTAssertNil(state.circuitBreakerUntil)
    }

    func testControllerFallsBackImmediatelyForDefinitiveCarrierLoss() throws {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "en0", gateway: .carrierDown)
        ])
        let routeSafety = RecordingRouteSafetyController()
        let defaults = isolatedDefaults()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: defaults,
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { routeSafety.appliedModes == [.localWiFi] })
    }

    func testControllerUsesThreeRapidHTTPSFailuresBeforeFallback() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "en0", gateway: .boundEgressUnavailable)
        ])
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber { interface in
                Self.probe(interface: interface, ready: interface == "en0")
            },
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { routeSafety.appliedModes == [.localWiFi] })
    }

    func testHealthyMiniRouteDoesNotReadRemoteHelper() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .ready)
        ])
        provider.helperStatus = readyHelperStatus()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: RecordingRouteSafetyController(),
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults()
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { provider.readCount == 1 })
        XCTAssertEqual(provider.helperReadCount, 0)
    }

    func testWiFiFallbackSkipsFailedCandidateAndUsesNextPinnedNetwork() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "en0", gateway: .carrierDown)
        ])
        let wifi = SequencedWiFiCandidateController(
            names: ["Primary", "Backup"],
            results: [.failed("authentication failed"), .connected]
        )
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: wifi,
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { controller.activeCandidateName == "Backup" })
        XCTAssertEqual(wifi.associationAttempts, ["Primary", "Backup"])
        XCTAssertEqual(routeSafety.appliedModes, [.localWiFi])
    }

    func testWiFiFallbackClosesMihomoConnectionsOnceThenRevalidates() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "en0", gateway: .carrierDown)
        ])
        let degraded = Self.probe(interface: "en0", ready: false, directReady: true)
        let prober = SequencedConnectivityProber(results: [
            degraded,
            degraded,
            Self.probe(interface: "en0", ready: true)
        ])
        let mihomo = CountingMihomoRecovery()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: RecordingRouteSafetyController(),
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: prober,
            mihomoRecovery: mihomo,
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { controller.lastClashAction == "已清理 Mihomo 旧连接" })
        XCTAssertEqual(mihomo.closeCount, 1)
        XCTAssertEqual(controller.activeCandidateName, "Test WiFi")
    }

    func testManagedWiFiFallbackAcceptsHealthyClashDataPlaneWithoutDirectHTTPS() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "en0", gateway: .carrierDown)
        ])
        let managed = ConnectivityProbeResult(
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
        let mihomo = CountingMihomoRecovery()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: RecordingRouteSafetyController(),
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: SequencedConnectivityProber(results: [managed, managed]),
            mihomoRecovery: mihomo,
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { controller.policyMessage == "Wi-Fi 已保网 · 直连受限，Clash/TUN 正常" })
        XCTAssertEqual(mihomo.closeCount, 0)
    }

    func testRedactedCurrentWiFiCanBeUsedWithoutScanningOrAssociation() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "bridge0", gateway: .carrierDown),
            policySnapshot(interface: "en0", gateway: .carrierDown)
        ])
        let wifi = EmptyWiFiCandidateController()
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: wifi,
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { controller.activeCandidateName == "当前已连接 Wi-Fi" })
        XCTAssertEqual(wifi.associationAttempts, 0)
        XCTAssertEqual(routeSafety.appliedModes, [.localWiFi])
    }

    func testAlreadyHealthyWiFiDoesNotRepeatRouteFallbackOrOpenCircuit() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .carrierDown),
            policySnapshot(interface: "en0", gateway: .carrierDown)
        ])
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.readCount == 1 })
        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.readCount == 2 })

        XCTAssertTrue(routeSafety.appliedModes.isEmpty)
        XCTAssertNotEqual(controller.failoverPhase, .routeFlapping)
    }

    func testControllerSwitchesBackOnlyAfterThirtyStableSeconds() throws {
        var currentTime = Date(timeIntervalSince1970: 3_000)
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "bridge0", gateway: .ready)
        ])
        provider.helperStatus = readyHelperStatus()
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            now: { currentTime },
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { controller.stabilizationRemaining == 30 })
        XCTAssertTrue(routeSafety.appliedModes.isEmpty)

        currentTime = currentTime.addingTimeInterval(31)
        controller.runPolicyCheckNow()

        XCTAssertTrue(
            waitUntil { routeSafety.appliedModes == [.macMiniGateway] },
            "modes=\(routeSafety.appliedModes) reads=\(provider.readCount) message=\(controller.policyMessage ?? "nil")"
        )
    }

    func testControllerRestoresWiFiWhenAutomaticSwitchVerificationFails() throws {
        var currentTime = Date(timeIntervalSince1970: 4_000)
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "en0", gateway: .boundEgressUnavailable)
        ])
        provider.helperStatus = readyHelperStatus()
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: SequencedConnectivityProber(results: [
                Self.probe(interface: "bridge0", ready: true),
                Self.probe(interface: "bridge0", ready: true),
                Self.probe(interface: "bridge0", ready: false),
                Self.probe(interface: "en0", ready: true),
                Self.probe(interface: "en0", ready: true)
            ]),
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            now: { currentTime },
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { controller.stabilizationRemaining == 30 })
        currentTime = currentTime.addingTimeInterval(31)
        controller.runPolicyCheckNow()

        XCTAssertTrue(
            waitUntil { routeSafety.appliedModes == [.macMiniGateway, .localWiFi] },
            "modes=\(routeSafety.appliedModes) reads=\(provider.readCount) message=\(controller.policyMessage ?? "nil")"
        )
    }

    func testHelperV3DecodesGuardianAndClassifiesSpecificFailure() throws {
        let json = """
        {
          "protocolVersion": 3,
          "configured": true,
          "serviceIPv4": "192.168.2.1",
          "gatewayIPv4": "192.168.2.1",
          "upstreamDevice": "en0",
          "upstreamActive": false,
          "sharingConfigured": true,
          "internetSharingRunning": false,
          "guardian": {
            "state": "carrierDown",
            "lastTransition": "2026-08-25T17:47:11Z",
            "lastCarrierChange": "2026-08-25T17:47:11Z",
            "lastAction": "carrier inactive",
            "lastError": null,
            "carrierActive": false,
            "addressReady": false,
            "routeReady": false,
            "sharingRunning": false,
            "sharingConfigured": true,
            "upstreamReachable": false,
            "nextRetryAt": null
          }
        }
        """

        let status = try JSONDecoder().decode(MacMiniHelperStatus.self, from: Data(json.utf8))

        XCTAssertEqual(status.protocolVersion, 3)
        XCTAssertEqual(status.gatewayState, .carrierDown)
        XCTAssertEqual(status.guardian?.lastCarrierChange, "2026-08-25T17:47:11Z")
        XCTAssertEqual(status.guardian?.lastAction, "carrier inactive")
    }

    func testRouteSafetyHelperHasExactNoArgumentContract() throws {
        let bundle = Bundle.module
        let helper = try XCTUnwrap(bundle.url(
            forResource: "netbar-route-safety-helper",
            withExtension: nil,
            subdirectory: "RouteSafetyHelper"
        ))
        let installer = try XCTUnwrap(bundle.url(
            forResource: "install-netbar-route-safety-helper",
            withExtension: "command",
            subdirectory: "RouteSafetyHelper"
        ))
        let sudoers = try XCTUnwrap(bundle.url(
            forResource: "com.zjah.NetBarRouteSafetyHelper",
            withExtension: "sudoers",
            subdirectory: "RouteSafetyHelper"
        ))

        XCTAssertNotEqual(run("/bin/zsh", [helper.path, "unknown"]).exitCode, 0)
        XCTAssertNotEqual(run("/bin/zsh", [helper.path, "status", "extra"]).exitCode, 0)

        let helperSource = try String(contentsOf: helper)
        let installerSource = try String(contentsOf: installer)
        let sudoersSource = try String(contentsOf: sudoers)
        for command in ["status", "prefer-wifi", "prefer-mini", "rollback"] {
            XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarRouteSafetyHelper \(command)"))
        }
        XCTAssertFalse(sudoersSource.contains("com.zjah.NetBarRouteSafetyHelper *"))
        XCTAssertTrue(installerSource.contains("visudo -cf"))
        XCTAssertFalse(helperSource.contains("setdnsservers"))
        XCTAssertFalse(helperSource.contains("ifconfig utun"))
        XCTAssertTrue(helperSource.contains("for attempt in {1..12}"))
        XCTAssertTrue(helperSource.contains("mode_from_order"))
        XCTAssertTrue(helperSource.contains("(( mini_index > wifi_index ))"))
        XCTAssertTrue(helperSource.contains("(( wifi_index > mini_index ))"))
    }

    private func run(_ executable: String, _ arguments: [String]) -> NetworkModeCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return .init(exitCode: process.terminationStatus, standardOutput: "", standardError: "")
        } catch {
            return .init(exitCode: -1, standardOutput: "", standardError: error.localizedDescription)
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "netbar-policy-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(timeout: TimeInterval = 1, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    private func policySnapshot(interface: String, gateway: MacMiniGatewayState) -> NetworkModeSnapshot {
        let wifi = NetworkServiceEntry(
            name: "Wi-Fi",
            hardwarePort: "Wi-Fi",
            device: "en0",
            isDisabled: false
        )
        let thunderbolt = NetworkServiceEntry(
            name: "Thunderbolt Bridge",
            hardwarePort: "Thunderbolt Bridge",
            device: "bridge0",
            isDisabled: false
        )
        return NetworkModeSnapshot(
            services: interface == "bridge0" ? [thunderbolt, wifi] : [wifi, thunderbolt],
            wifiServiceName: "Wi-Fi",
            wifiDevice: "en0",
            thunderboltServiceName: "Thunderbolt Bridge",
            thunderboltDevice: "bridge0",
            bridgeIPv4: "192.168.2.2",
            miniGateway: "192.168.2.1",
            physicalDefaultInterface: interface,
            linkState: .connected,
            gatewayState: gateway
        )
    }

    private func readyHelperStatus() -> MacMiniHelperStatus {
        MacMiniHelperStatus(
            protocolVersion: 3,
            configured: true,
            serviceIPv4: "192.168.2.1",
            gatewayIPv4: "192.168.2.1",
            upstreamDevice: "en0",
            upstreamActive: true,
            sharingConfigured: true,
            internetSharingRunning: true,
            guardian: MacMiniGuardianStatus(
                state: .ready,
                lastTransition: nil,
                lastCarrierChange: nil,
                lastAction: nil,
                lastError: nil,
                carrierActive: true,
                addressReady: true,
                routeReady: true,
                sharingRunning: true,
                sharingConfigured: true,
                upstreamReachable: true,
                nextRetryAt: nil
            )
        )
    }

    fileprivate static func probe(
        interface: String,
        ready: Bool,
        directReady: Bool? = nil
    ) -> ConnectivityProbeResult {
        ConnectivityProbeResult(
            interfaceName: interface,
            carrierActive: true,
            ipv4Address: interface == "en0" ? "10.0.0.2" : "192.168.2.2",
            gateway: interface == "en0" ? "10.0.0.1" : "192.168.2.1",
            directHTTPSReachable: directReady ?? ready,
            clashControllerReachable: true,
            clashHTTPSReachable: ready,
            systemHTTPSReachable: ready,
            physicalDefaultInterface: interface
        )
    }
}

private final class PolicyWiFiCandidateController: WiFiCandidateControlling {
    func snapshot(pinnedSSIDs: [String]) -> WiFiCandidateSnapshot {
        let candidate = NetworkAccessCandidate(
            id: WiFiCandidateSelector.candidateID(for: "Test WiFi"),
            kind: .wifi,
            displayName: "Test WiFi",
            interfaceName: "en0",
            state: .internetReady,
            signalStrength: -45,
            isPinned: true,
            isCurrent: true
        )
        return .init(
            candidates: [candidate],
            currentSSID: "Test WiFi",
            savedSSIDs: ["Test WiFi"],
            visibleSSIDs: ["Test WiFi"],
            locationAccess: .allowed
        )
    }

    func associate(ssid: String) -> WiFiAssociationResult { .connected }
    func requestLocationAccess() {}
    func startMonitoring(onChange: @escaping () -> Void) {}
    func stopMonitoring() {}
}

private final class SequencedWiFiCandidateController: WiFiCandidateControlling {
    private let names: [String]
    private var results: [WiFiAssociationResult]
    private(set) var associationAttempts: [String] = []

    init(names: [String], results: [WiFiAssociationResult]) {
        self.names = names
        self.results = results
    }

    func snapshot(pinnedSSIDs: [String]) -> WiFiCandidateSnapshot {
        let candidates = names.map {
            NetworkAccessCandidate(
                id: WiFiCandidateSelector.candidateID(for: $0),
                kind: .wifi,
                displayName: $0,
                interfaceName: "en0",
                state: .localOnly,
                signalStrength: -55,
                isPinned: true,
                isCurrent: false
            )
        }
        return .init(
            candidates: candidates,
            currentSSID: nil,
            savedSSIDs: Set(names),
            visibleSSIDs: Set(names),
            locationAccess: .allowed
        )
    }

    func associate(ssid: String) -> WiFiAssociationResult {
        associationAttempts.append(ssid)
        return results.isEmpty ? .unavailable : results.removeFirst()
    }
    func requestLocationAccess() {}
    func startMonitoring(onChange: @escaping () -> Void) {}
    func stopMonitoring() {}
}

private final class EmptyWiFiCandidateController: WiFiCandidateControlling {
    private(set) var associationAttempts = 0

    func snapshot(pinnedSSIDs: [String]) -> WiFiCandidateSnapshot {
        .init(
            candidates: [],
            currentSSID: nil,
            savedSSIDs: [],
            visibleSSIDs: [],
            locationAccess: .notDetermined
        )
    }

    func associate(ssid: String) -> WiFiAssociationResult {
        associationAttempts += 1
        return .failed("must not associate a redacted SSID")
    }
    func requestLocationAccess() {}
    func startMonitoring(onChange: @escaping () -> Void) {}
    func stopMonitoring() {}
}

private final class PolicyConnectivityProber: ConnectivityProbing {
    private let result: (String) -> ConnectivityProbeResult

    init(result: @escaping (String) -> ConnectivityProbeResult = {
        NetworkRoutePolicyTests.probe(interface: $0, ready: true)
    }) {
        self.result = result
    }

    func probe(interfaceName: String) -> ConnectivityProbeResult { result(interfaceName) }
}

private final class SequencedConnectivityProber: ConnectivityProbing {
    private let lock = NSLock()
    private var results: [ConnectivityProbeResult]

    init(results: [ConnectivityProbeResult]) { self.results = results }

    func probe(interfaceName: String) -> ConnectivityProbeResult {
        lock.lock()
        defer { lock.unlock() }
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? NetworkRoutePolicyTests.probe(interface: interfaceName, ready: false)
    }
}

private final class PolicyMihomoRecovery: MihomoRouteRecovering {
    func isControllerAvailable() -> Bool { true }
    func probeHTTPS() -> Bool { true }
    func closeAllConnections() -> Bool { true }
}

private final class CountingMihomoRecovery: MihomoRouteRecovering {
    private(set) var closeCount = 0
    func isControllerAvailable() -> Bool { true }
    func probeHTTPS() -> Bool { false }
    func closeAllConnections() -> Bool {
        closeCount += 1
        return true
    }
}

private final class PolicyEventLogger: NetworkEventLogging {
    func record(event: String, detail: String, candidateSSID: String?) {}
}

private final class PolicySnapshotProvider: NetworkModeSystemProviding {
    func readSnapshot() throws -> NetworkModeSnapshot {
        NetworkModeSnapshot(
            services: [
                .init(name: "Wi-Fi", hardwarePort: "Wi-Fi", device: "en0", isDisabled: false),
                .init(name: "Thunderbolt Bridge", hardwarePort: "Thunderbolt Bridge", device: "bridge0", isDisabled: false)
            ],
            wifiServiceName: "Wi-Fi",
            wifiDevice: "en0",
            thunderboltServiceName: "Thunderbolt Bridge",
            thunderboltDevice: "bridge0",
            bridgeIPv4: "192.168.2.2",
            miniGateway: "192.168.2.1",
            physicalDefaultInterface: "en0",
            linkState: .connected,
            gatewayState: .ready
        )
    }

    func setServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: "", standardError: "")
    }
}

private final class PolicyRouteSafetyController: RouteSafetyControlling {
    func status() -> RouteSafetyHelperStatus? { nil }
    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: "", standardError: "")
    }
    func openInstaller() -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: "", standardError: "")
    }
}

private final class SequencedPolicyProvider: NetworkModeSystemProviding {
    private let lock = NSLock()
    private var snapshots: [NetworkModeSnapshot]
    var helperStatus: MacMiniHelperStatus?
    private(set) var readCount = 0
    private(set) var helperReadCount = 0

    init(snapshots: [NetworkModeSnapshot]) {
        self.snapshots = snapshots
    }

    func readSnapshot() throws -> NetworkModeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard !snapshots.isEmpty else { throw NetworkModeSystemError.commandFailed("no snapshot") }
        return snapshots.count == 1 ? snapshots[0] : snapshots.removeFirst()
    }

    func setServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: "", standardError: "")
    }

    func readMacMiniHelperStatus() -> MacMiniHelperStatus? {
        lock.lock()
        helperReadCount += 1
        lock.unlock()
        return helperStatus
    }
}

private final class RecordingRouteSafetyController: RouteSafetyControlling {
    private let lock = NSLock()
    private var modes: [NetworkRouteMode] = []
    var appliedModes: [NetworkRouteMode] {
        lock.lock()
        defer { lock.unlock() }
        return modes
    }

    func status() -> RouteSafetyHelperStatus? {
        .init(
            protocolVersion: 1,
            mode: "wifi",
            wifiService: "Wi-Fi",
            wifiDevice: "en0",
            miniService: "Thunderbolt Bridge",
            backupAvailable: true
        )
    }

    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult {
        lock.lock()
        modes.append(mode)
        lock.unlock()
        return .init(exitCode: 0, standardOutput: "", standardError: "")
    }

    func openInstaller() -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: "", standardError: "")
    }
}
