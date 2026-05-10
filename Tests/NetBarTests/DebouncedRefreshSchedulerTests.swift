import XCTest
@testable import NetBar

final class DebouncedRefreshSchedulerTests: XCTestCase {
    func testSchedulesDelayedAction() {
        let expectation = expectation(description: "scheduled action runs")
        let scheduler = DebouncedRefreshScheduler(delay: 0.02, queue: .main)

        scheduler.schedule {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }

    func testReschedulingCancelsEarlierAction() {
        let expectation = expectation(description: "latest action runs")
        let scheduler = DebouncedRefreshScheduler(delay: 0.03, queue: .main)
        var calls: [String] = []

        scheduler.schedule {
            calls.append("first")
        }
        scheduler.schedule {
            calls.append("second")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(calls, ["second"])
    }
}
