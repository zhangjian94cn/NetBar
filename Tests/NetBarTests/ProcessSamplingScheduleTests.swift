import XCTest
@testable import NetBar

final class ProcessSamplingScheduleTests: XCTestCase {
    func testBackgroundSamplingAndVisibleCadencePreserveSingleFlight() {
        var schedule = ProcessSamplingSchedule()
        schedule.requestedInterval = 0.1
        schedule.start()
        let generation = schedule.begin(now: 0)!
        schedule.isVisible = true
        XCTAssertNil(schedule.begin(now: 1), "Opening the panel must not overlap a slow worker")
        schedule.complete(generation: generation, succeeded: true, now: 3)
        XCTAssertNil(schedule.begin(now: 4))
        XCTAssertEqual(schedule.begin(now: 5), generation)
        schedule.complete(generation: generation, succeeded: true, now: 6)
        schedule.isVisible = false
        XCTAssertNil(schedule.begin(now: 15))
        XCTAssertEqual(schedule.begin(now: 16), generation)
    }

    func testPersistentFailureHasBoundedRetriesAndVisibilityCannotBypassCooldown() {
        var schedule = ProcessSamplingSchedule()
        schedule.start()
        var attempts = 0
        for second in 0..<300 {
            schedule.isVisible = second.isMultiple(of: 2)
            schedule.requestedInterval = 0.01
            if let generation = schedule.begin(now: Double(second)) {
                attempts += 1
                schedule.complete(generation: generation, succeeded: false, now: Double(second))
            }
        }
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(schedule.waitTime(now: 300), 165)
        let generation = schedule.begin(now: 465)!
        schedule.complete(generation: generation, succeeded: true, now: 466)
        XCTAssertEqual(schedule.failures, 0)
        XCTAssertEqual(schedule.delay, 10)
    }

    func testRestartDoesNotOverlapOldWorkerOrAcceptItsResult() {
        var schedule = ProcessSamplingSchedule()
        schedule.start()
        let oldGeneration = schedule.begin(now: 0)!
        schedule.stop()
        XCTAssertNil(schedule.begin(now: 10))
        schedule.start()
        XCTAssertNil(schedule.begin(now: 11))
        XCTAssertFalse(schedule.complete(generation: oldGeneration, succeeded: false, now: 12))
        XCTAssertEqual(schedule.failures, 0)
        let newGeneration = schedule.begin(now: 12)
        XCTAssertNotNil(newGeneration)
        XCTAssertNotEqual(oldGeneration, newGeneration)
    }
}
