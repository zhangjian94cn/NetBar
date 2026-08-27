import XCTest
import NetBarMiniNetworkGuardianSupport

final class MiniGuardianRecoveryPlannerTests: XCTestCase {
    func testCarrierDownOnlyWaitsForCarrier() {
        XCTAssertEqual(decide(carrierActive: false), .carrierDown)
    }

    func testConfigurationDriftRefusesAddressOrSharingRepair() {
        XCTAssertEqual(
            decide(preferencesMatch: false, addressReady: false, routeReady: false),
            .configurationDrift("en0 manual configuration differs from NetBar profile")
        )
        XCTAssertEqual(
            decide(sharingConfigured: false, sharingRunning: false),
            .configurationDrift("Internet Sharing must use en0 and include bridge0")
        )
    }

    func testAddressRecoveryWaitsFifteenSecondsThenReappliesManualIPv4() {
        XCTAssertEqual(
            decide(addressReady: false, routeReady: false, addressWaitElapsed: nil),
            .addressRecovering(15)
        )
        XCTAssertEqual(
            decide(addressReady: false, routeReady: false, addressWaitElapsed: 14),
            .addressRecovering(1)
        )
        XCTAssertEqual(
            decide(addressReady: false, routeReady: false, addressWaitElapsed: 15),
            .reapplyAddress
        )
    }

    func testSharingRecoveryWaitsFifteenSecondsThenRestartsNativeSharing() {
        XCTAssertEqual(
            decide(sharingRunning: false, upstreamReachable: false, sharingWaitElapsed: nil),
            .sharingRecovering(15)
        )
        XCTAssertEqual(
            decide(sharingRunning: false, upstreamReachable: false, sharingWaitElapsed: 15),
            .restartSharing
        )
    }

    func testRunningSharingProcessWithoutKernelForwardingIsNotReady() {
        XCTAssertEqual(
            decide(forwardingEnabled: false, sharingWaitElapsed: nil),
            .sharingRecovering(15)
        )
        XCTAssertEqual(
            decide(forwardingEnabled: false, sharingWaitElapsed: 15),
            .restartSharing
        )
    }

    func testFreshDownstreamEgressFailureRestartsSharingWhenLocalFactsAreHealthy() {
        XCTAssertEqual(
            decide(downstreamEgressFailureReported: true),
            .restartSharing
        )
        XCTAssertEqual(
            decide(downstreamEgressFailureReported: true, retryRemaining: 42),
            .recoveryBackoff(42)
        )
    }

    func testFailedRepairAndPersistedBackoffFailClosed() {
        XCTAssertEqual(
            decide(upstreamReachable: false, pendingRepairVerification: true),
            .repairFailed
        )
        XCTAssertEqual(
            decide(upstreamReachable: false, retryRemaining: 45),
            .recoveryBackoff(45)
        )
    }

    func testHealthyStateStabilizesAndResetsBackoffOnlyAfterSixtySeconds() {
        XCTAssertEqual(decide(healthyElapsed: 0), .readyStabilizing(30))
        XCTAssertEqual(decide(healthyElapsed: 29), .readyStabilizing(1))
        XCTAssertEqual(decide(healthyElapsed: 30), .ready(resetBackoff: false))
        XCTAssertEqual(decide(healthyElapsed: 60), .ready(resetBackoff: true))
    }

    func testServiceParserDoesNotTreatHardwarePortLineAsServiceTitle() {
        let output = """
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en1)
        (2) *Ethernet Company Manual
        (Hardware Port: Ethernet, Device: en0)
        (3) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        """

        XCTAssertEqual(
            NetworkServiceOrderParser.serviceName(forDevice: "en0", in: output),
            "Ethernet Company Manual"
        )
        XCTAssertEqual(
            NetworkServiceOrderParser.serviceName(forDevice: "bridge0", in: output),
            "Thunderbolt Bridge"
        )
    }

    private func decide(
        carrierActive: Bool = true,
        preferencesMatch: Bool = true,
        sharingConfigured: Bool = true,
        addressReady: Bool = true,
        routeReady: Bool = true,
        sharingRunning: Bool = true,
        forwardingEnabled: Bool = true,
        downstreamEgressFailureReported: Bool = false,
        upstreamReachable: Bool = true,
        pendingRepairVerification: Bool = false,
        retryRemaining: TimeInterval? = nil,
        addressWaitElapsed: TimeInterval? = nil,
        sharingWaitElapsed: TimeInterval? = nil,
        healthyElapsed: TimeInterval? = 60
    ) -> MiniGuardianRecoveryDecision {
        MiniGuardianRecoveryPlanner.decide(
            MiniGuardianRecoveryInput(
                carrierActive: carrierActive,
                preferencesMatch: preferencesMatch,
                sharingConfigured: sharingConfigured,
                addressReady: addressReady,
                routeReady: routeReady,
                sharingRunning: sharingRunning,
                forwardingEnabled: forwardingEnabled,
                downstreamEgressFailureReported: downstreamEgressFailureReported,
                upstreamReachable: upstreamReachable,
                pendingRepairVerification: pendingRepairVerification,
                retryRemaining: retryRemaining,
                addressWaitElapsed: addressWaitElapsed,
                sharingWaitElapsed: sharingWaitElapsed,
                healthyElapsed: healthyElapsed
            )
        )
    }
}
