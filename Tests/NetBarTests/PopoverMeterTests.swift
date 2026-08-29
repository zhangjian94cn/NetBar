import XCTest
@testable import NetBar

final class PopoverMeterTests: XCTestCase {
    func testUndefinedProportionsReturnNilRatherThanZero() {
        // A zero limit means "unlimited" for VPS quota, and "nothing measured
        // yet" for a share. Neither is 0%, so the bar must be omitted.
        XCTAssertNil(PopoverMeter.fraction(UInt64(12), of: UInt64(0)))
        XCTAssertNil(PopoverMeter.fraction(0.0, of: 0.0))
        XCTAssertNil(PopoverMeter.fraction(5.0, of: Double.nan))
        XCTAssertNil(PopoverMeter.fraction(Double.infinity, of: 10.0))
    }

    func testProportionsAreClampedToTheUnitRange() {
        XCTAssertEqual(PopoverMeter.fraction(UInt64(25), of: UInt64(100)) ?? -1, 0.25, accuracy: 0.0001)
        // Over-quota must render full, not overflow the track.
        XCTAssertEqual(PopoverMeter.fraction(UInt64(150), of: UInt64(100)) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(PopoverMeter.fraction(-5.0, of: 100.0) ?? -1, 0.0, accuracy: 0.0001)
    }

    func testSparklineNeedsAFullWindowAndANonZeroPeak() {
        let size = CGSize(width: 100, height: 20)
        XCTAssertTrue(PopoverSparkline.points([], in: size).isEmpty)
        // A short window would render as a stray rule, not a trend.
        XCTAssertTrue(PopoverSparkline.points([1, 2, 3, 4, 5], in: size).isEmpty)
        XCTAssertTrue(PopoverSparkline.points([0, 0, 0, 0, 0, 0], in: size).isEmpty)
    }

    func testSparklineSpansTheWidthAndInvertsForScreenCoordinates() {
        let size = CGSize(width: 100, height: 20)
        let points = PopoverSparkline.points([0, 2, 4, 6, 8, 10], in: size)

        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(points.first?.x ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(points.last?.x ?? -1, 100, accuracy: 0.0001)
        // Zero sits on the baseline; the peak stops short of the ceiling.
        XCTAssertEqual(points.first?.y ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(points.last?.y ?? -1, 4, accuracy: 0.0001)
    }

    func testSteadyRateDoesNotFlattenAgainstTheTopEdge() {
        let size = CGSize(width: 100, height: 20)
        let points = PopoverSparkline.points(Array(repeating: 5.0, count: 8), in: size)

        XCTAssertEqual(points.count, 8)
        // Every point must sit below the ceiling, otherwise a constant rate
        // draws a hard line along the top and reads as a divider.
        for point in points {
            XCTAssertGreaterThan(point.y, 0)
            XCTAssertEqual(point.y, 4, accuracy: 0.0001)
        }
    }

    func testSpeedHistoryStaysBounded() {
        let monitor = NetworkMonitor()
        XCTAssertTrue(monitor.speedHistory.isEmpty)
        XCTAssertEqual(NetworkMonitor.speedHistoryLimit, 60)
    }

    func testSpeedTotalCombinesBothDirections() {
        XCTAssertEqual(NetworkMonitor.Speed(download: 30, upload: 12).total, 42)
        XCTAssertEqual(NetworkMonitor.Speed.zero.total, 0)
    }
}
