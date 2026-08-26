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
            userDefaults: defaults
        )

        XCTAssertEqual(controller.routePreference, .miniPreferred)
        controller.switchMode(to: .localWiFi)
        XCTAssertEqual(controller.routePreference, .localWiFi)

        let reloaded = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
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

    func testTwoFallbacksWithinTenMinutesOpenCircuitForTenMinutes() {
        let start = Date(timeIntervalSince1970: 2_000)
        var state = NetworkRoutePolicyState(preference: .miniPreferred)

        state.recordAutomaticFallback(at: start)
        XCTAssertNil(state.circuitBreakerUntil)
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
            policySnapshot(interface: "en0", gateway: .carrierDown)
        ])
        let routeSafety = RecordingRouteSafetyController()
        let defaults = isolatedDefaults()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            userDefaults: defaults
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { routeSafety.appliedModes == [.localWiFi] })
    }

    func testControllerRequiresThreeGenericBoundEgressFailuresBeforeFallback() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "en0", gateway: .boundEgressUnavailable)
        ])
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            userDefaults: isolatedDefaults()
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.readCount >= 1 })
        XCTAssertTrue(routeSafety.appliedModes.isEmpty)

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.readCount >= 2 })
        XCTAssertTrue(routeSafety.appliedModes.isEmpty)

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
            userDefaults: isolatedDefaults()
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { provider.readCount == 1 })
        XCTAssertEqual(provider.helperReadCount, 0)
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
            userDefaults: isolatedDefaults(),
            now: { currentTime }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { controller.stabilizationRemaining == 30 })
        XCTAssertTrue(routeSafety.appliedModes.isEmpty)

        currentTime = currentTime.addingTimeInterval(31)
        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { routeSafety.appliedModes == [.macMiniGateway] })
    }

    func testControllerRestoresWiFiWhenAutomaticSwitchVerificationFails() throws {
        var currentTime = Date(timeIntervalSince1970: 4_000)
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "en0", gateway: .boundEgressUnavailable)
        ])
        provider.helperStatus = readyHelperStatus()
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            userDefaults: isolatedDefaults(),
            now: { currentTime }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { controller.stabilizationRemaining == 30 })
        currentTime = currentTime.addingTimeInterval(31)
        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil {
            routeSafety.appliedModes == [.macMiniGateway, .localWiFi]
        })
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
