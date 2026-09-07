import XCTest
@testable import NetBar

final class Ping0PageParserTests: XCTestCase {
    /// 2026-09-07 实测快照（代理出口 204.2.62.104），锚点见
    /// skill spec contracts/ping0-dom-anchors.md
    private static let fullFixture = """
    {"ip":"204.2.62.104","location":"美国 加利福尼亚州 洛杉矶","asn":"AS2914","asnName":"NTT America, Inc.","org":"NTT America, Inc.","ipType":"家庭宽带 IP","riskPercent":"8%","nativeText":"原生 IP","aiText":"家庭宽带的概率为 52%","sharedUsers":"1 - 10 (极好)"}
    """

    func testParseFullFixture() throws {
        let info = try Ping0PageParser.parse(extractionJSON: Self.fullFixture)

        XCTAssertEqual(info.ip, "204.2.62.104")
        XCTAssertEqual(info.ipVersion, .ipv4)
        XCTAssertEqual(info.locationRaw, "美国 加利福尼亚州 洛杉矶")
        XCTAssertEqual(info.asn, "AS2914")
        XCTAssertEqual(info.asnName, "NTT America, Inc.")
        XCTAssertEqual(info.org, "NTT America, Inc.")
        XCTAssertEqual(info.ipTypeText, "家庭宽带 IP")
        XCTAssertEqual(info.isIDC, false)
        XCTAssertEqual(info.ipRisk, 8)
        XCTAssertEqual(info.riskPercentText, "8%")
        XCTAssertEqual(info.riskTier, .extremelyPure)
        XCTAssertEqual(info.isNative, true)
        XCTAssertEqual(info.aiDetectionText, "家庭宽带的概率为 52%")
        XCTAssertEqual(info.sharedUsersText, "1 - 10 (极好)")
        XCTAssertEqual(info.source, "ping0-web")
        XCTAssertEqual(info.riskLabel, "风控值 8% · 极度纯净")
    }

    func testParseMainlandIPWithoutSharedUsersAndPendingAIDetection() throws {
        let mainland = """
        {"ip":"113.110.79.21","location":"中国 广东 广州","asn":"AS4134","asnName":"Chinanet","org":"Chinanet Guangdong","ipType":"家庭宽带 IP","riskPercent":"8%","nativeText":"原生 IP","aiText":"","sharedUsers":""}
        """
        let info = try Ping0PageParser.parse(extractionJSON: mainland)

        XCTAssertEqual(info.ip, "113.110.79.21")
        XCTAssertNil(info.sharedUsersText)
        XCTAssertNil(info.aiDetectionText)
        XCTAssertEqual(info.ipRisk, 8)
    }

    func testParseIDCAndBroadcastIP() throws {
        let idc = """
        {"ip":"45.150.165.158","location":"美国 华盛顿州 西雅图","asn":"AS201106","asnName":"Spartan Host","org":"Spartan Host Ltd","ipType":"IDC机房IP","riskPercent":"40%","nativeText":"广播 IP","aiText":"","sharedUsers":"100 - 1000 (风险)"}
        """
        let info = try Ping0PageParser.parse(extractionJSON: idc)

        XCTAssertEqual(info.isIDC, true)
        XCTAssertEqual(info.isNative, false)
        XCTAssertEqual(info.ipRisk, 40)
        XCTAssertEqual(info.riskTier, .slightRisk)
        XCTAssertEqual(info.riskLabel, "风控值 40% · 轻微风险")
    }

    func testParseDegradesFieldByFieldWhenKeysMissing() throws {
        let minimal = """
        {"ip":"1.2.3.4"}
        """
        let info = try Ping0PageParser.parse(extractionJSON: minimal)

        XCTAssertEqual(info.ip, "1.2.3.4")
        XCTAssertNil(info.locationRaw)
        XCTAssertNil(info.asn)
        XCTAssertNil(info.ipRisk)
        XCTAssertNil(info.ipTypeText)
        XCTAssertNil(info.sharedUsersText)
        XCTAssertNil(info.aiDetectionText)
        XCTAssertEqual(info.riskLabel, "基础归属地")
    }

    func testParseIPv6Address() throws {
        let info = try Ping0PageParser.parse(extractionJSON: #"{"ip":"240e:1234::1"}"#)
        XCTAssertEqual(info.ipVersion, .ipv6)
    }

    func testParseThrowsWithoutIP() {
        XCTAssertThrowsEgressParseError {
            try Ping0PageParser.parse(extractionJSON: #"{"riskPercent":"8%"}"#)
        }
    }

    func testParseThrowsOnGarbage() {
        XCTAssertThrowsEgressParseError {
            try Ping0PageParser.parse(extractionJSON: "not-json")
        }
    }

    private func XCTAssertThrowsEgressParseError(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("Expected invalidJSONResponse", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? EgressIPError, .invalidJSONResponse, file: file, line: line)
        }
    }
}
