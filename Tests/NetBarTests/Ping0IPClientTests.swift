import XCTest
@testable import NetBar

final class Ping0IPClientTests: XCTestCase {
    override func tearDown() {
        Ping0URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testGeoURLSelection() {
        XCTAssertEqual(Ping0IPClient.geoURL(for: .auto).absoluteString, "https://ping0.cc/geo")
        XCTAssertEqual(Ping0IPClient.geoURL(for: .ipv4).absoluteString, "https://ipv4.ping0.cc/geo")
        XCTAssertEqual(Ping0IPClient.geoURL(for: .ipv6).absoluteString, "https://ipv6.ping0.cc/geo")
    }

    func testParseGeoResponse() throws {
        let info = try Ping0IPClient.parseGeoResponse("""
        45.150.165.158
        美国 华盛顿州 西雅图
        AS201106
        Spartan Host Ltd
        """)

        XCTAssertEqual(info.ip, "45.150.165.158")
        XCTAssertEqual(info.ipVersion, .ipv4)
        XCTAssertEqual(info.locationRaw, "美国 华盛顿州 西雅图")
        XCTAssertEqual(info.asn, "AS201106")
        XCTAssertEqual(info.org, "Spartan Host Ltd")
        XCTAssertNil(info.ipRisk)
        XCTAssertEqual(info.locationDisplay, "美国 华盛顿州 西雅图")
        XCTAssertEqual(info.riskLabel, "基础归属地")
    }

    func testParseDetailJSON() throws {
        let info = try Ping0IPClient.parseDetailJSON([
            "ip": "111.112.113.114",
            "location": "中国 宁夏回族自治区固原市中国电信",
            "country": "中国",
            "province": "宁夏回族自治区",
            "city": "固原市",
            "asn": "AS4134",
            "asnname": "Chinanet Backbone",
            "org": "CHINANET ningxia province network",
            "isidc": false,
            "iprisk": 5,
            "isnative": true,
            "asntype": "isp",
            "orgtype": "isp"
        ])

        XCTAssertEqual(info.ip, "111.112.113.114")
        XCTAssertEqual(info.ipRisk, 5)
        XCTAssertEqual(info.isIDC, false)
        XCTAssertEqual(info.isNative, true)
        XCTAssertEqual(info.asnType, "isp")
        XCTAssertEqual(info.orgType, "isp")
        XCTAssertEqual(info.locationRaw, "中国 宁夏回族自治区固原市中国电信")
        XCTAssertEqual(info.locationDisplay, "中国 / 宁夏回族自治区 / 固原市")
    }

    func testLookupCurrentIPDoesNotCallPaidAPIWithoutKey() async throws {
        var paths: [String] = []
        Ping0URLProtocolStub.handler = { request in
            paths.append(request.url?.path ?? "")
            return (Self.response(for: request, statusCode: 200), Self.geoData)
        }

        let info = try await makeClient().lookupCurrentIP(version: .auto, apiKey: nil)

        XCTAssertEqual(info.ip, "45.150.165.158")
        XCTAssertEqual(paths, ["/geo"])
    }

    func testLookupCurrentIPCallsPaidAPIWithKey() async throws {
        var paths: [String] = []
        Ping0URLProtocolStub.handler = { request in
            paths.append(request.url?.path ?? "")
            if request.url?.path == "/geo" {
                return (Self.response(for: request, statusCode: 200), Self.geoData)
            }
            return (Self.response(for: request, statusCode: 200), Self.detailData)
        }

        let info = try await makeClient().lookupCurrentIP(version: .auto, apiKey: "key123")

        XCTAssertEqual(info.ipRisk, 5)
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[1].contains("/apiloc/apikey(key123)/ip(45.150.165.158)"))
    }

    func testPaidJSONStructuredLocationOverridesFreeRawLocationButMissingFieldsFallback() async throws {
        Ping0URLProtocolStub.handler = { request in
            if request.url?.path == "/geo" {
                return (Self.response(for: request, statusCode: 200), Self.geoData)
            }
            let detailWithoutRawLocation = Data("""
            {"ip":"45.150.165.158","country":"美国","province":"华盛顿州","city":"西雅图","iprisk":10}
            """.utf8)
            return (Self.response(for: request, statusCode: 200), detailWithoutRawLocation)
        }

        let info = try await makeClient().lookupCurrentIP(version: .auto, apiKey: "key123")

        XCTAssertEqual(info.locationRaw, "美国 华盛顿州 西雅图")
        XCTAssertEqual(info.locationDisplay, "美国 / 华盛顿州 / 西雅图")
        XCTAssertEqual(info.asn, "AS201106")
        XCTAssertEqual(info.org, "Spartan Host Ltd")
        XCTAssertEqual(info.riskLabel, "纯净度: 风险值 10")
    }

    func testHTTPStatusError() async {
        Ping0URLProtocolStub.handler = { request in
            (Self.response(for: request, statusCode: 500), Data())
        }

        await XCTAssertThrowsEgressError(.httpStatus(500)) {
            _ = try await makeClient().lookupCurrentIP(version: .auto, apiKey: nil)
        }
    }

    func testInvalidGeoResponse() async {
        Ping0URLProtocolStub.handler = { request in
            (Self.response(for: request, statusCode: 200), Data("bad".utf8))
        }

        await XCTAssertThrowsEgressError(.invalidGeoResponse) {
            _ = try await makeClient().lookupCurrentIP(version: .auto, apiKey: nil)
        }
    }

    func testInvalidDetailJSON() async {
        Ping0URLProtocolStub.handler = { request in
            (Self.response(for: request, statusCode: 200), Data("not-json".utf8))
        }

        await XCTAssertThrowsEgressError(.invalidJSONResponse) {
            _ = try await makeClient().lookup(ip: "45.150.165.158", apiKey: "key")
        }
    }

    func testMissingIPInDetailJSON() async {
        Ping0URLProtocolStub.handler = { request in
            (Self.response(for: request, statusCode: 200), Data(#"{"iprisk":5}"#.utf8))
        }

        await XCTAssertThrowsEgressError(.invalidJSONResponse) {
            _ = try await makeClient().lookup(ip: "45.150.165.158", apiKey: "key")
        }
    }

    func testTimeoutError() async {
        Ping0URLProtocolStub.handler = { _ in
            throw URLError(.timedOut)
        }

        await XCTAssertThrowsEgressError(.timeout) {
            _ = try await makeClient().lookupCurrentIP(version: .auto, apiKey: nil)
        }
    }

    private func makeClient() -> Ping0IPClient {
        Ping0IPClient(session: Ping0URLProtocolStub.makeSession())
    }

    private static let geoData = Data("""
    45.150.165.158
    美国 华盛顿州 西雅图
    AS201106
    Spartan Host Ltd
    """.utf8)

    private static let detailData = Data("""
    {"ip":"45.150.165.158","location":"美国 华盛顿州 西雅图","country":"美国","province":"华盛顿州","city":"西雅图","asn":"AS201106","asnname":"Spartan Host","org":"Spartan Host Ltd","isidc":true,"iprisk":5,"isnative":true,"asntype":"hosting","orgtype":"business"}
    """.utf8)

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

private func XCTAssertThrowsEgressError(
    _ expected: EgressIPError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? EgressIPError, expected, file: file, line: line)
    }
}

private final class Ping0URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Ping0URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
