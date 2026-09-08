import XCTest
import NetworkExecution

final class NetworkExecutionTests: XCTestCase {
    func testTimeoutReapsCommand() {
        let result = BoundedCommand.run("/bin/sh", ["-c", "sleep 20"], timeout: 0.1)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(result.elapsed, 1)
    }
    func testBothPipesAreDrainedAndBounded() {
        let result = BoundedCommand.run("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"], timeout: 5, outputLimit: 1000)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 1000)
        XCTAssertEqual(result.stderr.utf8.count, 1000)
        XCTAssertTrue(result.outputTruncated)
    }
    func testCancellationDuringCommand() {
        let context = ProbeContext(timeout: 10)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { context.cancel() }
        let result = BoundedCommand.run("/bin/sleep", ["20"], context: context)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertLessThan(result.elapsed, 1)
    }
    func testParentBudgetAndScopeRestoration() {
        let context = ProbeContext(generation: 42, timeout: 0.1)
        ProbeContext.withValue(context) {
            XCTAssertEqual(ProbeContext.current?.generation, 42)
            let result = BoundedCommand.run("/bin/sleep", ["10"], timeout: 10)
            XCTAssertEqual(result.outcome, .timedOut)
            XCTAssertLessThan(result.elapsed, 1)
        }
        XCTAssertNil(ProbeContext.current)
    }
    func testInheritedPipeDoesNotHoldExitedParent() {
        let result = BoundedCommand.run("/bin/sh", ["-c", "sleep 20 & echo done"], timeout: 1)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("done"))
        XCTAssertLessThan(result.elapsed, 1)
    }
}

final class LatestEvaluationTests: XCTestCase {
    func testStormKeepsOnlyLatestPendingAndCancelsOldGeneration() {
        let queue = DispatchQueue(label: "test.latest")
        let scheduler = LatestEvaluation(queue: queue)
        let entered = expectation(description: "entered")
        let done = expectation(description: "latest")
        let release = DispatchSemaphore(value: 0)
        scheduler.submit(timeout: 3) { context in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            XCTAssertTrue(context.isCancelled)
        }
        wait(for: [entered], timeout: 1)
        for index in 0..<100 {
            scheduler.submit(timeout: 3, superseding: true) { context in
                XCTAssertEqual(index, 99)
                XCTAssertEqual(context.generation, 100)
                done.fulfill()
            }
        }
        XCTAssertEqual(scheduler.pendingCount, 1)
        release.signal()
        wait(for: [done], timeout: 1)
    }
    func testExpiredParentPreventsSubcommandLaunch() {
        let parent = ProbeContext(timeout: 0)
        let child = ProbeContext(timeout: 20, parent: parent)
        let result = BoundedCommand.run("/bin/echo", ["must not run"], context: child)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.stdout, "")
    }
}

extension NetworkExecutionTests {
    // 可选返回值曾经让 memoized 永远返回 nil、闭包一次都不跑，
    // 结果就是 Mini 的 helper status 从来没被真正读取过。
    func testMemoizedRunsOptionalWorkAndCachesItsResult() {
        let context = ProbeContext(timeout: 5)
        var calls = 0
        let first: String? = context.memoized("k") { calls += 1; return "value" }
        let second: String? = context.memoized("k") { calls += 1; return "other" }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(first, "value")
        XCTAssertEqual(second, "value")

        var nilCalls = 0
        let missing: String? = context.memoized("empty") { nilCalls += 1; return nil }
        let missingAgain: String? = context.memoized("empty") { nilCalls += 1; return "late" }
        XCTAssertEqual(nilCalls, 1, "缓存下来的 nil 也要复用，不能每轮重跑")
        XCTAssertNil(missing)
        XCTAssertNil(missingAgain)
    }
}
