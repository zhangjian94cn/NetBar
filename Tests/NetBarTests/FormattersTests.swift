import XCTest
@testable import NetBar

final class FormattersTests: XCTestCase {

    // MARK: - formatSpeed

    func testFormatSpeedZero() {
        let result = Formatters.formatSpeed(0)
        XCTAssertTrue(result.contains("0"), "Zero speed should show '0': got '\(result)'")
    }

    func testFormatSpeedBytes() {
        let result = Formatters.formatSpeed(500)
        XCTAssertTrue(result.contains("B") || result.contains("0"), "500 B/s: got '\(result)'")
    }

    func testFormatSpeedKB() {
        let result = Formatters.formatSpeed(15_000)
        XCTAssertTrue(result.contains("K") || result.contains("k"), "15 KB/s: got '\(result)'")
    }

    func testFormatSpeedMB() {
        let result = Formatters.formatSpeed(5_000_000)
        XCTAssertTrue(result.contains("M") || result.contains("m"), "5 MB/s: got '\(result)'")
    }

    func testFormatSpeedGB() {
        let result = Formatters.formatSpeed(2_000_000_000)
        XCTAssertTrue(result.contains("G") || result.contains("g"), "2 GB/s: got '\(result)'")
    }

    // MARK: - formatBytes

    func testFormatBytesZero() {
        let result = Formatters.formatBytes(0)
        XCTAssertTrue(result.contains("0"), "Zero bytes: got '\(result)'")
    }

    func testFormatBytesKB() {
        let result = Formatters.formatBytes(1500)
        XCTAssertTrue(result.contains("K") || result.contains("k"), "1500 bytes: got '\(result)'")
    }

    func testFormatBytesMB() {
        let result = Formatters.formatBytes(5_242_880)
        XCTAssertTrue(result.contains("M") || result.contains("m"), "5 MB: got '\(result)'")
    }

    func testFormatBytesGB() {
        let result = Formatters.formatBytes(2_147_483_648)
        XCTAssertTrue(result.contains("G") || result.contains("g"), "2 GB: got '\(result)'")
    }
}
