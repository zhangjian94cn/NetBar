import XCTest
import Combine
@testable import NetBar

final class VPSTrafficExperienceTests: XCTestCase {
    @MainActor func testFirstFailureHasNoDataAndLaterFailureRetainsLastSuccess() async throws {
        var fail = true
        VPSExperienceProtocol.respond = { proto in
            if fail { proto.fail(); return }
            proto.finish(proto.request.url!.path.hasSuffix("login") ? #"{"success":true}"# : #"{"success":true,"obj":[{"up":0,"down":0}]}"#)
        }
        let c = config(host: "one.test")
        let monitor = VPSTrafficMonitor(client: client(), configProvider: { [c] }, passwordProvider: { _ in "fixture" })
        monitor.refresh()
        await waitUntil { monitor.vpsList.first?.error != nil }
        XCTAssertFalse(try XCTUnwrap(monitor.vpsList.first).hasData)
        fail = false; monitor.refresh()
        await waitUntil { monitor.vpsList.first?.hasData == true }
        let success = try XCTUnwrap(monitor.vpsList.first?.lastUpdated)
        XCTAssertFalse(try XCTUnwrap(monitor.vpsList.first).quotaKnown)
        fail = true; monitor.refresh()
        await waitUntil { monitor.vpsList.first?.error != nil }
        XCTAssertEqual(monitor.vpsList.first?.lastUpdated, success)
        XCTAssertTrue(try XCTUnwrap(monitor.vpsList.first).hasData)
        XCTAssertNotNil(monitor.vpsList.first?.lastAttemptAt)
        monitor.stop()
    }
    @MainActor func testRepeatedRefreshIsSingleFlightAndOldConfigurationCannotOverwriteNew() async throws {
        var held: VPSExperienceProtocol?, loginCount = 0
        var c = config(host: "old.test")
        VPSExperienceProtocol.respond = { proto in
            if proto.request.url!.path.hasSuffix("login") {
                loginCount += 1; proto.finish(#"{"success":true}"#)
            } else if proto.request.url!.host == "old.test" { held = proto }
            else { proto.finish(#"{"success":true,"obj":[{"up":2,"down":3,"total":100}]}"#) }
        }
        let monitor = VPSTrafficMonitor(client: client(), configProvider: { [c] }, passwordProvider: { _ in "fixture" })
        monitor.refresh(); monitor.refresh(); monitor.refresh()
        await waitUntil { held != nil }
        XCTAssertEqual(loginCount, 1)
        c.host = "new.test"; c.name = "New"
        monitor.reloadConfigs()
        await waitUntil { monitor.vpsList.first?.name == "New" }
        held?.finish(#"{"success":true,"obj":[{"up":999,"down":999,"total":0}]}"#)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(monitor.vpsList.first?.download, 3)
        XCTAssertEqual(monitor.vpsList.first?.name, "New")
        monitor.stop()
    }
    private func config(host: String) -> AppConfig.VPSConfig {
        .init(id: "fixture", name: "Fixture", host: host, port: 443, basePath: "", username: "fixture", useTLS: true)
    }
    private func client() -> ThreeXUIClient {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [VPSExperienceProtocol.self]
        return .init(session: URLSession(configuration: c))
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }; try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for VPS result")
    }
}
private final class VPSExperienceProtocol: URLProtocol {
    static var respond: ((VPSExperienceProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.respond?(self) }
    override func stopLoading() {}
    func finish(_ json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie":"fixture=1; Path=/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
}
