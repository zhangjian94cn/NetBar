import Foundation
import XCTest
@testable import NetBar

final class NetworkPolicyShadowCoordinatorTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testRapidEventsCoalesceIntoOneGeneration() async throws {
        let logger = ShadowRecordingLogger()
        let coordinator = NetworkPolicyShadowCoordinator(
            eventLogger: logger,
            debounceNanoseconds: 20_000_000
        )
        await coordinator.networkDidChange(.physicalLink)
        await coordinator.networkDidChange(.addressing)
        await coordinator.networkDidChange(.routing)
        var diagnostic = await coordinator.diagnosticSnapshot()
        for _ in 0..<100 where diagnostic.generation == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            diagnostic = await coordinator.diagnosticSnapshot()
        }
        XCTAssertEqual(diagnostic.generation, 1)
        XCTAssertEqual(logger.events(named: "network_policy_shadow_generation").count, 1)
    }

    func testShadowOnlyLogsProposalAndNeverExecutesIt() async {
        let logger = ShadowRecordingLogger()
        let coordinator = NetworkPolicyShadowCoordinator(eventLogger: logger)
        await coordinator.observe(NetworkPolicyShadowObservation(
            intent: .miniPreferred,
            observedUnderlay: .mini,
            miniProof: .unavailable(.sharingUnavailable),
            wifiProof: .preflightEligible,
            observedAt: observedAt
        ))

        let diagnostic = await coordinator.diagnosticSnapshot()
        guard case .switching(_, .wifi) = diagnostic.state.phase else {
            return XCTFail("shadow reducer should propose Wi-Fi")
        }
        XCTAssertEqual(logger.events(named: "network_policy_shadow_proposal").count, 1)
        XCTAssertTrue(logger.events(named: "network_policy_shadow_proposal")[0].contains("effect=switchRoute"))
    }

    func testForwardingFailureMapsToUnavailableSharingProof() {
        let observation = NetworkPolicyShadowObservation.make(
            snapshot: makeSnapshot(gateway: .sharingForwardingUnavailable),
            preference: .miniPreferred,
            currentUnderlayVerified: false,
            wifiCandidates: [],
            observedAt: observedAt
        )
        XCTAssertEqual(observation.miniProof, .unavailable(.sharingUnavailable))
    }

    func testHealthyCurrentWiFiIsNotDisturbedWhenMiniIsUnknown() async {
        let logger = ShadowRecordingLogger()
        let coordinator = NetworkPolicyShadowCoordinator(eventLogger: logger)
        await coordinator.observe(NetworkPolicyShadowObservation(
            intent: .miniPreferred,
            observedUnderlay: .wifi,
            miniProof: .unknown,
            wifiProof: .activeVerified,
            observedAt: observedAt
        ))
        XCTAssertTrue(logger.events(named: "network_policy_shadow_proposal").isEmpty)
    }

    func testRemoteEvidenceChangeCreatesNewGenerationWithoutLocalRouteEvent() async {
        let logger = ShadowRecordingLogger()
        let coordinator = NetworkPolicyShadowCoordinator(eventLogger: logger)
        await coordinator.observe(NetworkPolicyShadowObservation(
            intent: .miniPreferred,
            observedUnderlay: .wifi,
            miniProof: .unknown,
            wifiProof: .activeVerified,
            observedAt: observedAt
        ))
        await coordinator.observe(NetworkPolicyShadowObservation(
            intent: .miniPreferred,
            observedUnderlay: .wifi,
            miniProof: .unavailable(.sharingUnavailable),
            wifiProof: .activeVerified,
            observedAt: observedAt.addingTimeInterval(10)
        ))
        let diagnostic = await coordinator.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.generation, 2)
        XCTAssertEqual(logger.events(named: "network_policy_shadow_generation").count, 1)
    }

    private func makeSnapshot(gateway: MacMiniGatewayState) -> NetworkModeSnapshot {
        NetworkModeSnapshot(
            services: [
                .init(name: "Thunderbolt Bridge", hardwarePort: "Thunderbolt Bridge", device: "bridge0", isDisabled: false),
                .init(name: "Wi-Fi", hardwarePort: "Wi-Fi", device: "en0", isDisabled: false)
            ],
            wifiServiceName: "Wi-Fi",
            wifiDevice: "en0",
            thunderboltServiceName: "Thunderbolt Bridge",
            thunderboltDevice: "bridge0",
            bridgeIPv4: "192.168.2.2",
            miniGateway: "192.168.2.1",
            physicalDefaultInterface: "en0",
            linkState: .connected,
            gatewayState: gateway
        )
    }
}

private final class ShadowRecordingLogger: NetworkEventLogging {
    private let lock = NSLock()
    private var recorded: [(String, String)] = []

    func record(event: String, detail: String, candidateSSID: String?) {
        lock.lock()
        recorded.append((event, detail))
        lock.unlock()
    }

    func events(named name: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.0 == name }.map(\.1)
    }
}
