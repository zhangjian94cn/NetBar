import XCTest
@testable import NetBar

final class VPSTrafficMonitorTests: XCTestCase {
    func testLoginFormBodyIsPercentEncoded() throws {
        let data = try XCTUnwrap(ThreeXUIClient.formEncodedBody(
            username: "a+b&c=中文",
            password: "p q+&="
        ))
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(body.contains("username=a%2Bb%26c%3D%E4%B8%AD%E6%96%87"))
        XCTAssertTrue(body.contains("password=p+q%2B%26%3D"))
    }
}
