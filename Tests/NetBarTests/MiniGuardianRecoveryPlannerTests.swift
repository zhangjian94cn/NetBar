import XCTest
import NetBarMiniNetworkGuardianSupport

final class MiniGuardianRecoveryPlannerTests: XCTestCase {
    func testAppleDHCPRequiresBridgeZeroInCurrentInterfaceListEncoding() {
        XCTAssertTrue(MiniGuardianRecoveryPlanner.appleDHCPEnabled(from: ["bridge100", "bridge0"]))
        XCTAssertFalse(MiniGuardianRecoveryPlanner.appleDHCPEnabled(from: ["bridge100", "en1"]))
        XCTAssertTrue(MiniGuardianRecoveryPlanner.appleDHCPEnabled(from: true))
        XCTAssertTrue(MiniGuardianRecoveryPlanner.appleDHCPEnabled(from: NSNumber(value: 1)))
        XCTAssertFalse(MiniGuardianRecoveryPlanner.appleDHCPEnabled(from: NSNumber(value: 2)))
    }

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
            .configurationDrift("Internet Sharing must use en0 and include Wi-Fi plus bridge0")
        )
    }

    func testSharingToggleOffIsManualPendingAndNeverRequestsRestart() {
        XCTAssertEqual(
            decide(sharingIntentEnabled: false, sharingRunning: false, sharingWaitElapsed: 900),
            .sharingManualPending
        )
    }

    func testDisabledAppleDHCPIsManualPendingAndNeverRestartsTheSharingProcess() {
        XCTAssertEqual(
            decide(dhcpServerEnabled: false, sharingRunning: true, sharingWaitElapsed: 900),
            .sharingManualPending
        )
    }

    func testManagementAliasIsRepairedButBridgeMustRemainDHCP() {
        XCTAssertEqual(decide(managementAddressReady: false), .reapplyManagementAlias)
        XCTAssertEqual(
            decide(bridgeUsesDHCP: false),
            .configurationDrift("Thunderbolt Bridge must use DHCP; fixed IPv4 conflicts with Internet Sharing")
        )
    }

    func testStaleLeaseOrRunningProcessAloneCannotProduceReady() {
        XCTAssertEqual(decide(sharedAddressReady: false), .sharingRecovering(15))
        XCTAssertEqual(decide(hotspotAPActive: false), .sharingRecovering(15))
        XCTAssertEqual(decide(forwardingEnabled: false), .sharingRecovering(15))
        XCTAssertEqual(decide(upstreamReachable: false), .sharingRecovering(15))
    }

    func testAddressRecoveryWaitsFifteenSecondsThenFailsClosedWithoutRewritingEn0() {
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
            .repairFailed
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

    func testNativeSharingProcessIdentityRequiresRunningAppleExecutableAndNumericPID() {
        let valid = """
            system/com.apple.NetworkSharing = {
                state = running
                program = /usr/libexec/InternetSharing
                pid = 22136
            }
            """
        XCTAssertEqual(NativeSharingProcessIdentity.pid(fromLaunchctlPrint: valid), 22_136)
        XCTAssertNil(NativeSharingProcessIdentity.pid(fromLaunchctlPrint: valid.replacingOccurrences(
            of: "/usr/libexec/InternetSharing",
            with: "/tmp/InternetSharing"
        )))
        XCTAssertNil(NativeSharingProcessIdentity.pid(fromLaunchctlPrint: valid.replacingOccurrences(
            of: "state = running",
            with: "state = exited"
        )))
        XCTAssertNil(NativeSharingProcessIdentity.pid(fromLaunchctlPrint: valid.replacingOccurrences(
            of: "pid = 22136",
            with: "pid = 22136; /bin/sh"
        )))

        let stopped = valid.replacingOccurrences(of: "state = running", with: "state = not running")
            .replacingOccurrences(of: "pid = 22136", with: "")
        XCTAssertTrue(NativeSharingProcessIdentity.isStoppedNativeService(launchctlPrint: stopped))
        XCTAssertFalse(NativeSharingProcessIdentity.isStoppedNativeService(launchctlPrint: valid))
        XCTAssertFalse(NativeSharingProcessIdentity.isStoppedNativeService(launchctlPrint: stopped.replacingOccurrences(
            of: "/usr/libexec/InternetSharing",
            with: "/tmp/InternetSharing"
        )))
    }

    func testPersistedKickstartSIPFailureResetsObsoleteBackoffAfterUpgrade() {
        XCTAssertTrue(GuardianPersistedRecoveryMigration.shouldResetBackoff(
            lastError: "Could not kickstart service com.apple.NetworkSharing: Operation not permitted while System Integrity Protection is engaged"
        ))
        XCTAssertFalse(GuardianPersistedRecoveryMigration.shouldResetBackoff(
            lastError: "Internet Sharing did not restore kernel forwarding"
        ))
        XCTAssertFalse(GuardianPersistedRecoveryMigration.shouldResetBackoff(lastError: nil))
    }

    func testBackoffThrottlesRepairsWithoutSuspendingFifteenSecondObservation() {
        XCTAssertEqual(GuardianEvaluationCadence.duringRecoveryBackoff(remaining: 900), 15)
        XCTAssertEqual(GuardianEvaluationCadence.duringRecoveryBackoff(remaining: 5), 5)
        XCTAssertEqual(GuardianEvaluationCadence.duringRecoveryBackoff(remaining: 0), 1)
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
        sharingIntentEnabled: Bool = true,
        dhcpServerEnabled: Bool = true,
        managementAddressReady: Bool = true,
        bridgeUsesDHCP: Bool = true,
        sharedAddressReady: Bool = true,
        hotspotAPActive: Bool = true,
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
                sharingIntentEnabled: sharingIntentEnabled,
                dhcpServerEnabled: dhcpServerEnabled,
                managementAddressReady: managementAddressReady,
                bridgeUsesDHCP: bridgeUsesDHCP,
                sharedAddressReady: sharedAddressReady,
                hotspotAPActive: hotspotAPActive,
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
