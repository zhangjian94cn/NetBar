import XCTest
import AppKit
@testable import NetBar

final class StatusBarViewTests: XCTestCase {
    /// The view used to compute a 64pt intrinsic width while the status item
    /// and the view frame were both hardcoded to 72, so 8pt of the item was
    /// dead space no layout constant knew about. Both must now come from the
    /// same source.
    func testIntrinsicWidthMatchesTheAdvertisedItemWidth() {
        let view = StatusBarView(
            frame: NSRect(x: 0, y: 0, width: StatusBarView.preferredWidth, height: 22)
        )
        XCTAssertEqual(view.intrinsicContentSize.width, StatusBarView.preferredWidth)
        XCTAssertEqual(view.intrinsicContentSize.height, 22)
    }

    /// The item is meaningfully narrower than the 72pt it used to reserve, and
    /// still wide enough for a common peak reading.
    func testItemWidthStaysCompact() {
        XCTAssertLessThan(StatusBarView.preferredWidth, 72)
        XCTAssertGreaterThan(StatusBarView.preferredWidth, 44)
    }

    /// Long readings must render without throwing or clipping the view.
    func testRendersEveryMagnitudeWithoutOverflowing() {
        let samples = [("0B/s", "0B/s"), ("7K/s", "6K/s"), ("999K/s", "185B/s"), ("1023.9M/s", "12.5M/s")]
        for sample in samples {
            let view = StatusBarView(
                frame: NSRect(x: 0, y: 0, width: StatusBarView.preferredWidth, height: 22)
            )
            view.update(upload: sample.0, download: sample.1)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return XCTFail("no bitmap for \(sample)")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            XCTAssertEqual(rep.size.width, StatusBarView.preferredWidth)
        }
    }
}
