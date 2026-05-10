import XCTest
@testable import NetBar

final class NettopParserTests: XCTestCase {

    // MARK: - extractAppName

    func testExtractAppNameWithPID() {
        XCTAssertEqual(NettopParser.extractAppName(from: "Safari.1234"), "Safari")
    }

    func testExtractAppNameWithMultipleDots() {
        XCTAssertEqual(NettopParser.extractAppName(from: "Google Chrome.5678"), "Google Chrome")
    }

    func testExtractAppNameWithoutPID() {
        XCTAssertEqual(NettopParser.extractAppName(from: "kernel_task"), "kernel_task")
    }

    func testExtractAppNameWithDottedName() {
        // "com.apple.WebKit.Networking.99" → "com.apple.WebKit.Networking"
        XCTAssertEqual(NettopParser.extractAppName(from: "com.apple.WebKit.Networking.99"), "com.apple.WebKit.Networking")
    }

    func testExtractAppNameEmpty() {
        XCTAssertEqual(NettopParser.extractAppName(from: ""), "")
    }

    // MARK: - parse

    func testParseEmptyOutput() {
        let result = NettopParser.parse("")
        XCTAssertTrue(result.stats.isEmpty)
        XCTAssertTrue(result.interfaces.isEmpty)
    }

    func testParseSingleProcessSummary() {
        let output = """
        Safari.1234 en0 1024 2048
        """
        let result = NettopParser.parse(output)
        XCTAssertEqual(result.stats["Safari.1234"]?.bytesIn, 1024)
        XCTAssertEqual(result.stats["Safari.1234"]?.bytesOut, 2048)
    }

    func testParseSkipsHeaderLine() {
        let output = """
                              bytes_in  bytes_out
        Safari.1234 en0 1024 2048
        """
        let result = NettopParser.parse(output)
        XCTAssertEqual(result.stats.count, 1)
    }

    func testParseConnectionLineFiltersLoopback() {
        // Connection lines prefixed with spaces should be filtered if interface is lo0
        let output = """
        Safari.1234 en0 0 0
           192.168.1.1:443 lo0 500 600
        """
        let result = NettopParser.parse(output)
        // lo0 connections should be filtered out
        XCTAssertEqual(result.stats["Safari.1234"]?.bytesIn ?? 0, 0)
    }

    func testParseConnectionLineFiltersFakeIP() {
        let output = """
        Safari.1234 en0 0 0
           198.18.0.1:443 en0 500 600
        """
        let result = NettopParser.parse(output)
        // 198.18.x fake-IP connections should be filtered
        XCTAssertEqual(result.stats["Safari.1234"]?.bytesIn ?? 0, 0)
    }

    func testParseRecordsInterfaces() {
        let output = """
        Safari.1234 en0 1024 2048
        """
        let result = NettopParser.parse(output)
        XCTAssertTrue(result.interfaces["Safari"]?.contains("en0") ?? false)
    }

    func testInactiveUtunDoesNotBecomeActiveTunnelRoute() {
        let output = """
        NeteaseMusic.1234 en0 0 0
           192.168.3.8:443 en0 100 200
           224.0.0.251:5353 utun9 50 60
        """
        let result = NettopParser.parse(output)

        XCTAssertEqual(result.interfaces["NeteaseMusic"], ["en0", "utun9"])
        XCTAssertTrue(TunnelRouteDetector.activeTunnelInterfaces(
            in: [TunnelRouteDetector.IPv4Route(destination: "224.0.0/24", interface: "utun9")],
            activeInterfaces: ["utun9"]
        ).isEmpty)
    }
}
