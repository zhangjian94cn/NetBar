import XCTest
@testable import NetBar

final class ThreeXUIClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testConnectionSucceedsWithValidLoginAndInbounds() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/xui/login" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Set-Cookie": "session=abc; Path=/"]
                )!
                return (response, #"{"success":true}"#.data(using: .utf8)!)
            }

            XCTAssertEqual(request.url?.path, "/xui/panel/api/inbounds/list")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"success":true,"obj":[{"up":10,"down":20,"allTime":30,"total":100,"protocol":"vless","port":443,"clientStats":[{"email":"a@example.com","up":1,"down":2,"allTime":3,"lastOnline":0}]}]}
            """.data(using: .utf8)!
            return (response, data)
        }

        let result = await makeClient().testConnection(config: makeConfig(), password: "secret")

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, "连接成功")
    }

    func testInvalidCredentialsReturnSpecificMessage() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"success":false,"msg":"bad user"}"#.data(using: .utf8)!)
        }

        let result = await makeClient().testConnection(config: makeConfig(), password: "wrong")

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("用户名或密码错误"))
    }

    func testHTTP404ReportsPanelPathError() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let result = await makeClient().testConnection(config: makeConfig(), password: "secret")

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "面板路径错误或 API 不兼容")
    }

    func testNonJSONReportsInvalidResponse() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("html".utf8))
        }

        let result = await makeClient().testConnection(config: makeConfig(), password: "secret")

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "面板响应不是有效的 3X-UI JSON")
    }

    func testInboundsShapeMismatchReportsAPIIncompatible() async {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/xui/login" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Set-Cookie": "session=abc; Path=/"]
                )!
                return (response, #"{"success":true}"#.data(using: .utf8)!)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"success":true,"obj":{}}"#.data(using: .utf8)!)
        }

        let result = await makeClient().testConnection(config: makeConfig(), password: "secret")

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "inbounds API 不兼容，请确认这是 3X-UI 面板")
    }

    private func makeClient() -> ThreeXUIClient {
        ThreeXUIClient(session: URLProtocolStub.makeSession())
    }

    private func makeConfig() -> AppConfig.VPSConfig {
        AppConfig.VPSConfig(
            id: "server-1",
            name: "Test Server",
            provider: .threeXUI,
            host: "example.test",
            port: 443,
            basePath: "xui",
            username: "demo",
            useTLS: true,
            allowSelfSignedCertificate: false
        )
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
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
