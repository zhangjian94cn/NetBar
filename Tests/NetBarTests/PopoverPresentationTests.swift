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
