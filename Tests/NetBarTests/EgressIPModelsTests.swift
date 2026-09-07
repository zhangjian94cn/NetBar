import XCTest
import SwiftUI
@testable import NetBar

final class EgressIPModelsTests: XCTestCase {
    func testRiskTierBoundariesFollowOfficialBands() {
        let expectations: [(Int, RiskTier?)] = [
            (0, .extremelyPure), (14, .extremelyPure),
            (15, .pure), (16, .pure), (24, .pure),
            (25, .neutral), (39, .neutral),
            (40, .slightRisk), (49, .slightRisk),
            (50, .moderateRisk), (69, .moderateRisk),
            (70, .extremeRisk), (71, .extremeRisk), (100, .extremeRisk),
        ]
        for (risk, expected) in expectations {
            XCTAssertEqual(RiskTier(risk: risk), expected, "risk=\(risk)")
        }
    }

    func testRiskTierDisplayNames() {
        XCTAssertEqual(RiskTier.extremelyPure.displayName, "极度纯净")
        XCTAssertEqual(RiskTier.pure.displayName, "纯净")
        XCTAssertEqual(RiskTier.neutral.displayName, "中性")
        XCTAssertEqual(RiskTier.slightRisk.displayName, "轻微风险")
        XCTAssertEqual(RiskTier.moderateRisk.displayName, "稍高风险")
        XCTAssertEqual(RiskTier.extremeRisk.displayName, "极度风险")
    }

    func testRiskLabelFormats() {
        // 网页链路：百分比 + 档位
        XCTAssertEqual(makeInfo(ipRisk: 8, riskPercentText: "8%").riskLabel, "风控值 8% · 极度纯净")
        // 付费接口链路：纯数值 + 档位
        XCTAssertEqual(makeInfo(ipRisk: 30).riskLabel, "风控值 30 · 中性")
        // 无风险值：回退基础形态
        XCTAssertEqual(makeInfo().riskLabel, "基础归属地")
    }

    func testRiskTierTintMapsToPopoverPalette() {
        XCTAssertEqual(RiskTier.extremelyPure.tint, PopoverVisualStyle.healthy)
        XCTAssertEqual(RiskTier.pure.tint, PopoverVisualStyle.healthy)
        XCTAssertEqual(RiskTier.neutral.tint, PopoverVisualStyle.warning)
        XCTAssertEqual(RiskTier.slightRisk.tint, PopoverVisualStyle.warning)
        XCTAssertEqual(RiskTier.moderateRisk.tint, PopoverVisualStyle.fault)
        XCTAssertEqual(RiskTier.extremeRisk.tint, PopoverVisualStyle.fault)
    }

    func testRiskTierOnInfoDerivesFromRisk() {
        XCTAssertNil(makeInfo().riskTier)
        XCTAssertEqual(makeInfo(ipRisk: 85).riskTier, .extremeRisk)
    }

    private func makeInfo(
        ipRisk: Int? = nil,
        riskPercentText: String? = nil
    ) -> EgressIPInfo {
        EgressIPInfo(
            ip: "1.2.3.4",
            ipVersion: .ipv4,
            locationRaw: nil,
            country: nil,
            province: nil,
            city: nil,
            asn: nil,
            asnName: nil,
            org: nil,
            isIDC: nil,
            ipRisk: ipRisk,
            isNative: nil,
            asnType: nil,
            orgType: nil,
            ipTypeText: nil,
            sharedUsersText: nil,
            aiDetectionText: nil,
            riskPercentText: riskPercentText,
            source: "ping0",
            fetchedAt: Date()
        )
    }
}
