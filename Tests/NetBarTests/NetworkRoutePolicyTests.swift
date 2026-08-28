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

    func testFailedAutomaticReturnRequiresRequalificationAndSecondFailureOpensCircuit() {
        let start = Date(timeIntervalSince1970: 2_500)
        var state = NetworkRoutePolicyState(preference: .miniPreferred)

        state.recordHealthy(at: start)
        XCTAssertEqual(state.stableDuration(at: start.addingTimeInterval(30)), 30)

        state.recordFailedAutomaticReturn(at: start.addingTimeInterval(30))
        XCTAssertEqual(state.stableDuration(at: start.addingTimeInterval(31)), 0)
        XCTAssertEqual(state.automaticFallbacks, [start.addingTimeInterval(30)])
        XCTAssertNil(state.circuitBreakerUntil)

        state.recordFailedAutomaticReturn(at: start.addingTimeInterval(90))
        XCTAssertEqual(state.circuitBreakerUntil, start.addingTimeInterval(690))
        XCTAssertEqual(state.phase, .routeFlapping)
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

    func testCarrierLossRepairsWiFiServiceOrderAfterMacOSAlreadyChangedDefaultRoute() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(
                interface: "en0",
                gateway: .carrierDown,
                intendedMode: .macMiniGateway
            ),
            policySnapshot(
                interface: "en0",
                gateway: .carrierDown,
                intendedMode: .macMiniGateway
            ),
            policySnapshot(
                interface: "en0",
                gateway: .carrierDown,
                intendedMode: .localWiFi
            )
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

    func testDownstreamFailureStartsEpisodeAndReportsGuardianOnlyOnceWhenWiFiFallbackFails() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable)
        ])
        let logger = RecordingPolicyEventLogger()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: RecordingRouteSafetyController(),
            wifiCandidateController: SequencedWiFiCandidateController(
                names: ["Unavailable"],
                results: [.unavailable, .unavailable]
            ),
            connectivityProber: PolicyConnectivityProber { interface in
                Self.probe(interface: interface, ready: false)
            },
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: logger,
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.egressReportCount == 1 })
        XCTAssertTrue(waitUntil { controller.failoverPhase == .temporaryWiFi })
        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.readCount >= 2 })

        XCTAssertEqual(provider.egressReportCount, 1)
        XCTAssertEqual(logger.events.filter { $0 == "wifi_fallback_started" }.count, 1)
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

    func testManagedMiniRouteStaysActiveWhenDirectHTTPSIsBlocked() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .ready)
        ])
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber { interface in
                Self.probe(interface: interface, ready: true, directReady: false)
            },
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { controller.policyMessage == "Mac mini 优先 · 当前出口正常" })
        XCTAssertTrue(routeSafety.appliedModes.isEmpty)
        XCTAssertEqual(controller.failoverPhase, .miniActive)
    }

    func testMiniPreferredRepairsServiceOrderWhileEffectiveRouteIsAlreadyMini() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .ready, intendedMode: .localWiFi),
            policySnapshot(interface: "bridge0", gateway: .ready, intendedMode: .macMiniGateway)
        ])
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber { interface in
                Self.probe(interface: interface, ready: true, directReady: false)
            },
            mihomoRecovery: PolicyMihomoRecovery(),
            eventLogger: PolicyEventLogger(),
            userDefaults: isolatedDefaults(),
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { routeSafety.appliedModes == [.macMiniGateway] })
        XCTAssertTrue(waitUntil { controller.snapshot?.isConsistent == true })
        XCTAssertEqual(controller.snapshot?.effectiveMode, .macMiniGateway)
        XCTAssertEqual(controller.policyMessage, "Mac mini 优先 · 当前出口正常")
        XCTAssertEqual(routeSafety.commitCount, 1)
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
        XCTAssertEqual(routeSafety.commitCount, 1)
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

        XCTAssertTrue(waitUntil { controller.lastClashAction == "物理出口已变化，Mihomo 连接已自动刷新" })
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
        XCTAssertEqual(mihomo.closeCount, 1)
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
        let mihomo = CountingMihomoRecovery()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: mihomo,
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
        XCTAssertEqual(mihomo.closeCount, 0, "同一物理出口的重复检查不得清理现有连接")
    }

    func testWiFiPreferredPolicyStillRebindsMihomoWhenPhysicalOutletChanges() throws {
        let defaults = isolatedDefaults()
        defaults.set(NetworkRoutePreference.localWiFi.rawValue, forKey: "networkRoutePreference")
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "bridge0", gateway: .ready)
        ])
        let mihomo = CountingMihomoRecovery()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: RecordingRouteSafetyController(),
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: mihomo,
            eventLogger: PolicyEventLogger(),
            userDefaults: defaults,
            sleeper: { _ in }
        )

        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.readCount == 1 })
        controller.runPolicyCheckNow()

        XCTAssertTrue(waitUntil { mihomo.closeCount == 1 })
        XCTAssertEqual(controller.lastClashAction, "物理出口已变化，Mihomo 连接已自动刷新")
    }

    func testControllerSwitchesBackOnlyAfterThirtyStableSeconds() throws {
        var currentTime = Date(timeIntervalSince1970: 3_000)
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "bridge0", gateway: .ready)
        ])
        provider.helperStatus = readyHelperStatus(observedAt: currentTime.addingTimeInterval(31))
        let routeSafety = RecordingRouteSafetyController()
        let mihomo = CountingMihomoRecovery()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber(),
            mihomoRecovery: mihomo,
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
        XCTAssertTrue(waitUntil { mihomo.closeCount == 1 })
        XCTAssertEqual(controller.lastClashAction, "物理出口已变化，Mihomo 连接已自动刷新")
        XCTAssertTrue(waitUntil { routeSafety.commitCount == 1 })
    }

    func testManagedNetworkSwitchesToMiniUsingGuardianAndRoutedDataPlane() {
        var currentTime = Date(timeIntervalSince1970: 3_500)
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "bridge0", gateway: .ready)
        ])
        provider.helperStatus = readyHelperStatus(observedAt: currentTime.addingTimeInterval(31))
        let routeSafety = RecordingRouteSafetyController()
        let controller = NetworkModeController(
            provider: provider,
            routeSafetyController: routeSafety,
            wifiCandidateController: PolicyWiFiCandidateController(),
            connectivityProber: PolicyConnectivityProber { interface in
                Self.probe(interface: interface, ready: true, directReady: false)
            },
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

        XCTAssertTrue(waitUntil { routeSafety.appliedModes == [.macMiniGateway] })
        XCTAssertFalse(routeSafety.appliedModes.contains(.localWiFi))
    }

    func testControllerRestoresWiFiWhenAutomaticSwitchVerificationFails() throws {
        var currentTime = Date(timeIntervalSince1970: 4_000)
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "en0", gateway: .ready),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "bridge0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "en0", gateway: .boundEgressUnavailable),
            policySnapshot(interface: "en0", gateway: .ready)
        ])
        provider.helperStatus = readyHelperStatus(observedAt: currentTime.addingTimeInterval(31))
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
        XCTAssertTrue(waitUntil { routeSafety.rollbackCount == 1 })
        XCTAssertTrue(waitUntil { routeSafety.commitCount == 1 })

        currentTime = currentTime.addingTimeInterval(10)
        controller.runPolicyCheckNow()
        XCTAssertTrue(waitUntil { provider.readCount >= 6 })
        XCTAssertEqual(
            routeSafety.appliedModes,
            [.macMiniGateway, .localWiFi],
            "首次试切失败后必须重新累计 30 秒健康窗口，不能立即再次切换"
        )
        XCTAssertEqual(controller.stabilizationRemaining, 30)
    }

    func testHelperV4DecodesRawFactsAndClassifiesSpecificFailure() throws {
        let json = """
        {
          "protocolVersion": 4,
          "configured": true,
          "serviceIPv4": "192.168.2.1",
          "gatewayIPv4": "192.168.2.1",
          "upstreamDevice": "en0",
          "upstreamActive": false,
          "sharingConfigured": true,
          "sharingProcessRunning": false,
          "forwardingEnabled": false,
          "guardianObservedAt": "2026-08-27T08:39:00Z",
          "guardianGeneration": 17,
          "evidenceConflict": false,
          "guardian": {
            "state": "carrierDown",
            "observedAt": "2026-08-27T08:39:00Z",
            "generation": 17,
            "lastTransition": "2026-08-25T17:47:11Z",
            "lastCarrierChange": "2026-08-25T17:47:11Z",
            "lastAction": "carrier inactive",
            "lastError": null,
            "carrierActive": false,
            "addressReady": false,
            "routeReady": false,
            "sharingRunning": false,
            "forwardingEnabled": false,
            "sharingConfigured": true,
            "upstreamReachable": false,
            "nextRetryAt": null
          }
        }
        """

        let status = try JSONDecoder().decode(MacMiniHelperStatus.self, from: Data(json.utf8))

        XCTAssertEqual(status.protocolVersion, 4)
        XCTAssertEqual(status.gatewayState, .carrierDown)
        XCTAssertEqual(status.guardian?.lastCarrierChange, "2026-08-25T17:47:11Z")
        XCTAssertEqual(status.guardian?.lastAction, "carrier inactive")
    }

    func testRunningSharingProcessWithoutForwardingCannotBeReady() {
        var status = readyHelperStatus()
        status = MacMiniHelperStatus(
            protocolVersion: status.protocolVersion,
            configured: status.configured,
            serviceIPv4: status.serviceIPv4,
            gatewayIPv4: status.gatewayIPv4,
            upstreamDevice: status.upstreamDevice,
            upstreamActive: status.upstreamActive,
            sharingConfigured: status.sharingConfigured,
            sharingProcessRunning: true,
            forwardingEnabled: false,
            guardianObservedAt: status.guardianObservedAt,
            guardianGeneration: status.guardianGeneration,
            evidenceConflict: false,
            guardian: nil
        )

        XCTAssertEqual(status.gatewayState, .sharingForwardingUnavailable)
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
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try String(contentsOf: repo.appendingPathComponent("Sources/NetBar/Monitors/NetworkModeController.swift"))
        for command in ["status", "prefer-wifi", "prefer-mini", "commit", "rollback"] {
            XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarRouteSafetyHelper \(command)"))
        }
        XCTAssertFalse(sudoersSource.contains("com.zjah.NetBarRouteSafetyHelper *"))
        XCTAssertTrue(installerSource.contains("visudo -cf"))
        XCTAssertTrue(installerSource.contains("LEGACY_BACKUP"))
        XCTAssertTrue(installerSource.contains("PENDING_TARGET"))
        XCTAssertFalse(helperSource.contains("setdnsservers"))
        XCTAssertFalse(helperSource.contains("ifconfig utun"))
        XCTAssertTrue(helperSource.contains("for attempt in {1..12}"))
        XCTAssertTrue(helperSource.contains("mode_from_order"))
        XCTAssertTrue(helperSource.contains("(( mini_index > wifi_index ))"))
        XCTAssertTrue(helperSource.contains("(( wifi_index > mini_index ))"))
        XCTAssertTrue(helperSource.contains("\\\"protocolVersion\\\":2"))
        XCTAssertTrue(helperSource.contains("pendingTransaction"))
        XCTAssertEqual(run("/bin/zsh", ["-n", helper.path]).exitCode, 0)
        XCTAssertEqual(
            controllerSource.components(separatedBy: "switchEngine.switchMode").count - 1,
            1,
            "普通出口切换必须使用免密受限 Helper；AppleScript 授权回退只保留给一次性固定链路初始化"
        )
    }

    func testStartupCommitsPendingRouteTransactionOnlyAfterDataPlaneVerification() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready)
        ])
        let routeSafety = RecordingRouteSafetyController(pendingTarget: "wifi")
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

        controller.startPolicyMonitoring()
        defer { controller.stopPolicyMonitoring() }

        XCTAssertTrue(waitUntil { routeSafety.commitCount == 1 })
        XCTAssertEqual(routeSafety.rollbackCount, 0)
    }

    func testStartupRollsBackPendingRouteTransactionWhenTargetIsNotVerified() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "bridge0", gateway: .ready)
        ])
        let routeSafety = RecordingRouteSafetyController(pendingTarget: "wifi")
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

        controller.startPolicyMonitoring()
        defer { controller.stopPolicyMonitoring() }

        XCTAssertTrue(waitUntil { routeSafety.rollbackCount == 1 })
        XCTAssertEqual(routeSafety.commitCount, 0)
    }

    func testStartupRollsBackCorruptedPendingRouteTargetWithoutGuessing() {
        let provider = SequencedPolicyProvider(snapshots: [
            policySnapshot(interface: "en0", gateway: .ready)
        ])
        let routeSafety = RecordingRouteSafetyController(pendingTarget: "corrupted")
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

        controller.startPolicyMonitoring()
        defer { controller.stopPolicyMonitoring() }

        XCTAssertTrue(waitUntil { routeSafety.rollbackCount == 1 })
        XCTAssertEqual(routeSafety.commitCount, 0)
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

    private func policySnapshot(
        interface: String,
        gateway: MacMiniGatewayState,
        intendedMode: NetworkRouteMode? = nil
    ) -> NetworkModeSnapshot {
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
        let intended = intendedMode ?? (interface == "bridge0" ? .macMiniGateway : .localWiFi)
        return NetworkModeSnapshot(
            services: intended == .macMiniGateway ? [thunderbolt, wifi] : [wifi, thunderbolt],
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

    private func readyHelperStatus(observedAt: Date = Date()) -> MacMiniHelperStatus {
        let timestamp = ISO8601DateFormatter().string(from: observedAt)
        return MacMiniHelperStatus(
            protocolVersion: 4,
            configured: true,
            serviceIPv4: "192.168.2.1",
            gatewayIPv4: "192.168.2.1",
            upstreamDevice: "en0",
            upstreamActive: true,
            sharingConfigured: true,
            sharingProcessRunning: true,
            forwardingEnabled: true,
            guardianObservedAt: timestamp,
            guardianGeneration: 1,
            evidenceConflict: false,
            guardian: MacMiniGuardianStatus(
                state: .ready,
                observedAt: timestamp,
                generation: 1,
                lastTransition: nil,
                lastCarrierChange: nil,
                lastAction: nil,
                lastError: nil,
                carrierActive: true,
                addressReady: true,
                routeReady: true,
                sharingRunning: true,
                forwardingEnabled: true,
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

private final class RecordingPolicyEventLogger: NetworkEventLogging {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(event: String, detail: String, candidateSSID: String?) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
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
    func commit() -> NetworkModeCommandResult { .init(exitCode: 0, standardOutput: "", standardError: "") }
    func rollback() -> NetworkModeCommandResult { .init(exitCode: 0, standardOutput: "", standardError: "") }
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
    private(set) var egressReportCount = 0

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


    func reportMacMiniEgressFailure() -> Bool {
        lock.lock()
        egressReportCount += 1
        lock.unlock()
        return true
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
    private var commits = 0
    private var rollbacks = 0
    private let pendingTarget: String?

    init(pendingTarget: String? = nil) {
        self.pendingTarget = pendingTarget
    }
    var commitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return commits
    }
    var rollbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rollbacks
    }

    func status() -> RouteSafetyHelperStatus? {
        .init(
            protocolVersion: 2,
            mode: "wifi",
            wifiService: "Wi-Fi",
            wifiDevice: "en0",
            miniService: "Thunderbolt Bridge",
            pendingTransaction: pendingTarget != nil,
            pendingTarget: pendingTarget ?? ""
        )
    }

    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult {
        lock.lock()
        modes.append(mode)
        lock.unlock()
        return .init(exitCode: 0, standardOutput: "", standardError: "")
    }

    func commit() -> NetworkModeCommandResult {
        lock.lock()
        commits += 1
        lock.unlock()
        return .init(exitCode: 0, standardOutput: "", standardError: "")
    }
    func rollback() -> NetworkModeCommandResult {
        lock.lock()
        rollbacks += 1
        lock.unlock()
        return .init(exitCode: 0, standardOutput: "", standardError: "")
    }

    func openInstaller() -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: "", standardError: "")
    }
}
