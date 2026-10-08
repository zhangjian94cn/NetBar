import XCTest
import Darwin
import NetworkExecution

final class CommandEnergyTests: XCTestCase {
    func testClosedPipesDoNotBusySpinWhileChildIsAlive() {
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = BoundedCommand.run("/bin/sh", ["-c", "exec 1>&- 2>&-; sleep 0.5"], timeout: 2)
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000_000
        print("closed-pipe wait: wall=\(result.elapsed)s threadCPU=\(cpu)s")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.elapsed, 0.45)
        XCTAssertLessThan(cpu, 0.1, "Closed pipes must be removed from poll, not wake it continuously")
    }

    func testClosedPipesStillHonorTimeout() {
        let result = BoundedCommand.run("/bin/sh", ["-c", "exec 1>&- 2>&-; trap '' TERM; sleep 20"], timeout: 0.1)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(result.elapsed, 1)
    }
}
