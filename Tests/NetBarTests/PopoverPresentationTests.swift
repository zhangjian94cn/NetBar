import XCTest
@testable import NetBar

final class PopoverPresentationTests: XCTestCase {
    func testDirectFullSectionsUseTheFourTopLevelDestinationsInOrder() {
        XCTAssertEqual(
            PopoverSection.available(for: .directFull),
            [.outlet, .clash, .applications, .monitoring]
        )
        XCTAssertEqual(PopoverSection.defaultSection(for: .directFull), .outlet)
    }

    func testAppStoreLiteExposesOnlyMonitoring() {
        XCTAssertEqual(PopoverSection.available(for: .appStoreLite), [.monitoring])
        XCTAssertEqual(PopoverSection.defaultSection(for: .appStoreLite), .monitoring)
        XCTAssertEqual(PopoverSection.resolve(storedValue: "outlet", flavor: .appStoreLite), .monitoring)
    }

    func testStoredSelectionResolvesAndInvalidValuesFallBack() {
        XCTAssertEqual(PopoverSection.resolve(storedValue: "applications", flavor: .directFull), .applications)
        XCTAssertEqual(PopoverSection.resolve(storedValue: "unknown", flavor: .directFull), .outlet)
        XCTAssertEqual(PopoverSection.resolve(storedValue: nil, flavor: .directFull), .outlet)
    }

    func testActiveVerifiedPresentationRequiresOverlayAndDNSForOnline() {
        let presentation = PopoverStatusPresentation(
            proofLevel: .activeVerified,
            effectiveMode: .macMiniGateway,
            overlay: overlay(health: .ready, dataPlaneReady: true, mode: .tunFull),
            dnsFacts: dns(dependency: .independent, ready: true),
            primaryReason: nil
        )

        XCTAssertEqual(presentation.connectivity, .online)
        XCTAssertEqual(presentation.tone, .positive)
        XCTAssertEqual(presentation.outletText, "Mac mini")
        XCTAssertEqual(presentation.clashText, "TUN")
        XCTAssertEqual(presentation.dnsText, "正常")
        XCTAssertFalse(presentation.needsAttention(.outlet))
        XCTAssertFalse(presentation.needsAttention(.clash))
        XCTAssertFalse(presentation.needsAttention(.monitoring))
    }

    func testOverlayFailureProducesLimitedStateWithoutChangingVerifiedOutlet() {
        let presentation = PopoverStatusPresentation(
            proofLevel: .activeVerified,
            effectiveMode: .localWiFi,
            overlay: overlay(health: .degraded, dataPlaneReady: false, mode: .systemProxy),
            dnsFacts: dns(dependency: .independent, ready: true),
            primaryReason: "  代理数据面未收敛  "
        )

        XCTAssertEqual(presentation.connectivity, .limited)
        XCTAssertEqual(presentation.outletText, "Wi-Fi")
        XCTAssertEqual(presentation.primaryReason, "代理数据面未收敛")
        XCTAssertFalse(presentation.needsAttention(.outlet))
        XCTAssertTrue(presentation.needsAttention(.clash))
    }

    func testMiniDependentDNSAndUnavailableRouteMapToStableAlerts() {
        let presentation = PopoverStatusPresentation(
            proofLevel: .unavailable,
            effectiveMode: nil,
            overlay: overlay(health: .ready, dataPlaneReady: true, mode: .tunFull),
            dnsFacts: dns(dependency: .miniDependent, ready: false),
            primaryReason: "雷雳未连接"
        )

        XCTAssertEqual(presentation.connectivity, .offline)
        XCTAssertEqual(presentation.tone, .negative)
        XCTAssertEqual(presentation.outletText, "待验证")
        XCTAssertEqual(presentation.dnsText, "依赖 Mini")
        XCTAssertTrue(presentation.needsAttention(.outlet))
        XCTAssertTrue(presentation.needsAttention(.monitoring))
        XCTAssertFalse(presentation.needsAttention(.applications))
    }

    // MARK: - Tab badges mark actionable work only

    func testInProgressProofLevelsDoNotBadgeTheOutletTab() {
        for level in [ConnectivityProofLevel.routeEligible, .preflightEligible, .degradedActive] {
            let presentation = PopoverStatusPresentation(
                proofLevel: level,
                effectiveMode: .localWiFi,
                overlay: overlay(health: .ready, dataPlaneReady: true, mode: .tunFull),
                dnsFacts: dns(dependency: .independent, ready: true),
                primaryReason: nil
            )
            XCTAssertFalse(
                presentation.needsAttention(.outlet),
                "\(level) is in-progress, not something the user can act on"
            )
        }
    }

    func testActionableOutletFaultBadgesEvenWhenTheRouteIsVerified() {
        let presentation = PopoverStatusPresentation(
            proofLevel: .activeVerified,
            effectiveMode: .localWiFi,
            overlay: overlay(health: .ready, dataPlaneReady: true, mode: .tunFull),
            dnsFacts: dns(dependency: .independent, ready: true),
            primaryReason: "路由事务需要手动恢复",
            outletFault: true
        )

        XCTAssertTrue(presentation.needsAttention(.outlet))
    }

    func testSwitchingClashDoesNotBadgeTheClashTab() {
        let presentation = PopoverStatusPresentation(
            proofLevel: .activeVerified,
            effectiveMode: .localWiFi,
            overlay: overlay(health: .switching, dataPlaneReady: false, mode: .tunFull),
            dnsFacts: dns(dependency: .independent, ready: true),
            primaryReason: nil
        )

        XCTAssertFalse(presentation.needsAttention(.clash))
    }

    func testUnsampledDNSDoesNotBadgeMonitoring() {
        let presentation = PopoverStatusPresentation(
            proofLevel: .routeEligible,
            effectiveMode: nil,
            overlay: overlay(health: .ready, dataPlaneReady: true, mode: .tunFull),
            dnsFacts: nil,
            primaryReason: nil
        )

        XCTAssertFalse(presentation.needsAttention(.monitoring))
        XCTAssertEqual(presentation.dnsText, "待检测")
    }

    // MARK: - Outlet presentation

    func testUnsampledOutletFactsAreUnknownRatherThanWarnings() {
        let presentation = NetworkOutletPresentation(
            snapshot: nil,
            helperStatus: nil,
            proofLevel: .unavailable,
            failoverPhase: .miniActive,
            routePreference: .miniPreferred,
            requiresManualRecovery: false,
            dnsFacts: nil,
            applicationFacts: nil
        )

        XCTAssertEqual(presentation.heroState, .unknown)
        XCTAssertEqual(presentation.linkStateDot, .unknown)
        XCTAssertEqual(presentation.sharingStateDot, .unknown)
        XCTAssertEqual(presentation.proofStateDot, .unknown)
        XCTAssertEqual(presentation.dnsState, .unknown)
        XCTAssertEqual(presentation.managementState, .unknown)
        XCTAssertEqual(presentation.hotspotAPState, .unknown)
        XCTAssertEqual(presentation.proxyUnawareState, .unknown)
        XCTAssertEqual(presentation.outletText, "待确认")
    }

    func testAddressTextOmitsUnknownHalvesInsteadOfPrintingDashes() {
        XCTAssertEqual(NetworkOutletPresentation.addressText(local: nil, mini: nil), "")
        XCTAssertEqual(NetworkOutletPresentation.addressText(local: "10.254.254.2", mini: nil), "本机 10.254.254.2")
        XCTAssertEqual(
            NetworkOutletPresentation.addressText(local: "10.254.254.2", mini: "192.168.2.1"),
            "本机 10.254.254.2 · Mini 192.168.2.1"
        )
    }

    func testFactStateTreatsNilAsUnknownAndFalseAsWarning() {
        XCTAssertEqual(PopoverFactState(ready: nil), .unknown)
        XCTAssertEqual(PopoverFactState(ready: false), .warning)
        XCTAssertEqual(PopoverFactState(ready: true), .ok)
    }

    func testPlaceholderDetailsAreDropped() {
        XCTAssertNil(PopoverFactTile.meaningfulDetail(nil))
        XCTAssertNil(PopoverFactTile.meaningfulDetail("—"))
        XCTAssertNil(PopoverFactTile.meaningfulDetail("  "))
        XCTAssertEqual(PopoverFactTile.meaningfulDetail(" 10.254.254.2 "), "10.254.254.2")
    }

    private func overlay(
        health: ClashOverlayHealth,
        dataPlaneReady: Bool,
        mode: ClashOverlayMode
    ) -> ClashOverlaySnapshot {
        ClashOverlaySnapshot(
            mode: mode,
            runtimeTunEnabled: mode == .tunFull,
            persistentTunEnabled: mode == .tunFull,
            systemProxyEnabled: true,
            coexistenceBaselineReady: true,
            dataPlaneReady: dataPlaneReady,
            health: health,
            reason: health == .ready ? nil : "not ready"
        )
    }

    private func dns(dependency: DNSResolverDependency, ready: Bool) -> DNSPathFacts {
        DNSPathFacts(
            serviceName: "Wi-Fi",
            interfaceName: "en0",
            configurationSource: .automatic,
            dependency: dependency,
            resolverCount: 1,
            systemResolutionReady: ready,
            generation: 1,
            observedAt: Date()
        )
    }
}
