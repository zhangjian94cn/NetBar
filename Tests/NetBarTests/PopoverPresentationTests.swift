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

    func testHealthyDNSWithLegacyMiniResolverStaysOnlineButBadgesMonitoring() {
        let presentation = PopoverStatusPresentation(
            proofLevel: .activeVerified,
            effectiveMode: .localWiFi,
            overlay: overlay(health: .ready, dataPlaneReady: true, mode: .tunFull),
            dnsFacts: dns(dependency: .independent, ready: true, hasLegacyMiniResolver: true),
            primaryReason: nil
        )

        XCTAssertEqual(presentation.connectivity, .online)
        XCTAssertEqual(presentation.dnsText, "正常 · 含旧 Mini DNS")
        XCTAssertTrue(presentation.needsAttention(.monitoring))
        XCTAssertFalse(presentation.needsAttention(.outlet))
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

    // FR-007: 共享关闭要说清楚，读不到状态时不能推断成关闭。
    func testSharingOffIsNamedExplicitlyWhileUnreadableStaysUnknown() {
        let off = NetworkOutletPresentation(
            snapshot: outletSnapshot(linkState: .miniUnreachable, gatewayState: .unknown),
            helperStatus: helperStatus(sharingIntentEnabled: false),
            proofLevel: .unavailable,
            failoverPhase: .temporaryWiFi,
            routePreference: .miniPreferred,
            requiresManualRecovery: false,
            dnsFacts: nil,
            applicationFacts: nil
        )
        XCTAssertEqual(off.sharingValue, "互联网共享未开启")
        XCTAssertEqual(off.sharingDetail, "Mac mini：系统设置 → 通用 → 共享")

        let unreadable = NetworkOutletPresentation(
            snapshot: outletSnapshot(linkState: .miniUnreachable, gatewayState: .unknown),
            helperStatus: nil,
            proofLevel: .unavailable,
            failoverPhase: .temporaryWiFi,
            routePreference: .miniPreferred,
            requiresManualRecovery: false,
            dnsFacts: nil,
            applicationFacts: nil
        )
        XCTAssertEqual(unreadable.sharingValue, "共享状态未知")
        XCTAssertNotEqual(unreadable.sharingValue, off.sharingValue)
    }

    // US3: 雷雳插着但管理通道断了，不能笼统报"不可用"。
    func testConnectedCableIsReportedSeparatelyFromManagementReachability() {
        let presentation = NetworkOutletPresentation(
            snapshot: outletSnapshot(linkState: .miniUnreachable, gatewayState: .unknown),
            helperStatus: nil,
            proofLevel: .unavailable,
            failoverPhase: .temporaryWiFi,
            routePreference: .miniPreferred,
            requiresManualRecovery: false,
            dnsFacts: nil,
            applicationFacts: nil
        )
        XCTAssertEqual(presentation.linkValue, "设备已连接")
        XCTAssertEqual(presentation.linkDetail, "管理通道不可达")

        let unplugged = NetworkOutletPresentation(
            snapshot: outletSnapshot(linkState: .disconnected, gatewayState: .unknown, physicalLinkActive: false),
            helperStatus: nil,
            proofLevel: .unavailable,
            failoverPhase: .temporaryWiFi,
            routePreference: .miniPreferred,
            requiresManualRecovery: false,
            dnsFacts: nil,
            applicationFacts: nil
        )
        XCTAssertEqual(unplugged.linkValue, "雷雳未连接")
    }

    private func outletSnapshot(
        linkState: ThunderboltLinkState,
        gatewayState: MacMiniGatewayState,
        physicalLinkActive: Bool = true
    ) -> NetworkModeSnapshot {
        NetworkModeSnapshot(
            services: [
                NetworkServiceEntry(name: "Wi-Fi", hardwarePort: "Wi-Fi", device: "en0", isDisabled: false),
                NetworkServiceEntry(
                    name: "Thunderbolt Bridge",
                    hardwarePort: "Thunderbolt Bridge",
                    device: "bridge0",
                    isDisabled: false
                )
            ],
            wifiServiceName: "Wi-Fi",
            wifiDevice: "en0",
            thunderboltServiceName: "Thunderbolt Bridge",
            thunderboltDevice: "bridge0",
            bridgeIPv4: nil,
            miniGateway: nil,
            physicalDefaultInterface: "en0",
            linkState: linkState,
            gatewayState: gatewayState,
            physicalLinkActive: physicalLinkActive
        )
    }

    private func helperStatus(sharingIntentEnabled: Bool) -> MacMiniHelperStatus {
        MacMiniHelperStatus(
            protocolVersion: 5,
            configured: false,
            serviceIPv4: nil,
            gatewayIPv4: nil,
            managementIPv4: "10.254.254.1",
            managementPeerIPv4: "10.254.254.2",
            bridgeUsesDHCP: true,
            sharingIntentEnabled: sharingIntentEnabled,
            hotspotAPConfigured: false,
            upstreamDevice: "en0",
            upstreamActive: true,
            sharingConfigured: false,
            sharingProcessRunning: false,
            forwardingEnabled: false,
            guardianObservedAt: ISO8601DateFormatter().string(from: Date()),
            guardianGeneration: 1,
            evidenceConflict: false,
            guardian: nil
        )
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

    private func dns(
        dependency: DNSResolverDependency,
        ready: Bool,
        hasLegacyMiniResolver: Bool = false
    ) -> DNSPathFacts {
        DNSPathFacts(
            serviceName: "Wi-Fi",
            interfaceName: "en0",
            configurationSource: .automatic,
            dependency: dependency,
            resolverCount: 1,
            hasLegacyMiniResolver: hasLegacyMiniResolver,
            systemResolutionReady: ready,
            generation: 1,
            observedAt: Date()
        )
    }
}
