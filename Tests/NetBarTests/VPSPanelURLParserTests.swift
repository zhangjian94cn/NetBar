import XCTest
@testable import NetBar

final class VPSPanelURLParserTests: XCTestCase {
    func testParsesFullURL() throws {
        let parsed = try VPSPanelURLParser.parse("https://example.com:2053/custom/path/")

        XCTAssertTrue(parsed.useTLS)
        XCTAssertEqual(parsed.host, "example.com")
        XCTAssertEqual(parsed.port, 2053)
        XCTAssertEqual(parsed.basePath, "custom/path")
    }

    func testDefaultsSchemeAndPort() throws {
        let parsed = try VPSPanelURLParser.parse("example.com")

        XCTAssertTrue(parsed.useTLS)
        XCTAssertEqual(parsed.host, "example.com")
        XCTAssertEqual(parsed.port, 443)
        XCTAssertEqual(parsed.basePath, "")
    }

    func testDefaultsHTTPPort() throws {
        let parsed = try VPSPanelURLParser.parse("http://example.com/panel")

        XCTAssertFalse(parsed.useTLS)
        XCTAssertEqual(parsed.port, 80)
        XCTAssertEqual(parsed.basePath, "panel")
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try VPSPanelURLParser.parse("ftp://example.com")) { error in
            XCTAssertEqual(error as? VPSConnectionError, .unsupportedScheme("ftp"))
        }
    }

    func testRejectsMissingHost() {
        XCTAssertThrowsError(try VPSPanelURLParser.parse("https://:2053")) { error in
            XCTAssertEqual(error as? VPSConnectionError, .missingHost)
        }
    }

    func testRejectsInvalidURL() {
        XCTAssertThrowsError(try VPSPanelURLParser.parse("https://example.com:abc")) { error in
            XCTAssertTrue(error is VPSConnectionError)
        }
    }
}
