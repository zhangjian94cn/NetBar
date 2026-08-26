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

    private func decide(
        carrierActive: Bool = true,
        preferencesMatch: Bool = true,
        sharingConfigured: Bool = true,
        addressReady: Bool = true,
        routeReady: Bool = true,
        sharingRunning: Bool = true,
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
