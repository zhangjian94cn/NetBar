import XCTest
import Darwin
@testable import NetBar

final class NetworkEventLoggerEnergyTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("events.jsonl")
    }

    func testLargeHistoryIsNotReparsedOrRewrittenOnEveryEvent() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let row = "{\"timestamp\":\"\(timestamp)\",\"event\":\"history\",\"detail\":\"\(String(repeating: "x", count: 100))\"}\n"
        try Data(String(repeating: row, count: 8000).utf8).write(to: file)
        let logger = NetworkEventLogger(fileURL: file)
        logger.record(event: "startup", detail: "first maintenance")
        logger.flush()
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let started = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for index in 0..<50 { logger.record(event: "probe_\(index)", detail: "unique event") }
        logger.flush()
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - started) / 1_000_000_000
        print("50 log appends with large history: processCPU=\(cpu)s")
        XCTAssertLessThan(cpu, 0.5, "Appending must not repeatedly parse historical timestamps")
        let afterInode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(inode, afterInode, "Ordinary records must append without replacing the history file")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("probe_49"))
        XCTAssertEqual(text.split(separator: "\n").count, 8051)
    }

    func testRotationLeavesHeadroomAndOnlyCompleteJSONLines() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let logger = NetworkEventLogger(fileURL: file, maxBytes: 2048)
        for index in 0..<100 { logger.record(event: "event_\(index)", detail: String(repeating: "x", count: 60)) }
        logger.flush()
        let data = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(data.count, 2048)
        let rows = try data.split(separator: 0x0A).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: String] }
        XCTAssertEqual(rows.last?["event"], "event_99")
        XCTAssertFalse(rows.contains { $0["event"] == "event_0" })
        XCTAssertGreaterThan(rows.count, 1)
    }

    func testPeriodicMaintenanceRemovesNewlyExpiredEntries() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var now = Date()
        let logger = NetworkEventLogger(fileURL: file, now: { now })
        logger.record(event: "old", detail: "expires")
        logger.flush()
        now = now.addingTimeInterval(7 * 24 * 3600 + 1)
        logger.record(event: "fresh", detail: "keep")
        logger.flush()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("expires"))
        XCTAssertTrue(text.contains("keep"))
    }

    func testOversizedAndMalformedHistoryRecoversWithinSizeBudget() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data(repeating: 120, count: 10000).write(to: file)
        let logger = NetworkEventLogger(fileURL: file, maxBytes: 1024)
        logger.record(event: "fresh", detail: "recover")
        logger.flush()
        let data = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(data.count, 1024)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(object?["event"], "fresh")
    }
}
