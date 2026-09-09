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

extension NetworkExecutionTests {
    // root 的注释声明「证据按 generation 复用，memo 活在本轮 context 上，而不是探针为自己
    // 预算创建的短命 child 上」，但 memoized/store 读写的是 self.cache。当前没出问题只是因为
    // 调用点恰好都在 round context 上：boundDirectEgressReady 显式写了 .root，
    // MihomoClient 与 readMacMiniHelperStatus 没写。这条语义没有任何测试守护。
    func testMemoIsSharedAcrossTheWholeRoundNotPerChildContext() {
        let round = ProbeContext(timeout: 10)
        let child = ProbeContext(timeout: 2, parent: round)

        var calls = 0
        let fromChild: String? = child.memoized("shared") { calls += 1; return "first" }
        let fromRound: String? = round.memoized("shared") { calls += 1; return "second" }
        let fromSibling: String? = ProbeContext(timeout: 2, parent: round)
            .memoized("shared") { calls += 1; return "third" }

        XCTAssertEqual(calls, 1, "同一轮内同一 key 只应求值一次")
        XCTAssertEqual(fromChild, "first")
        XCTAssertEqual(fromRound, "first", "child 里算出的证据，本轮 context 必须能看到")
        XCTAssertEqual(fromSibling, "first", "同一轮的另一个探针不应重新求值")
    }

    // store 的语义是「失败读取保持可重试」，它同样必须落在本轮而不是短命 child 上，
    // 否则 MihomoClient 缓存的成功结果会随探针一起消失。
    func testStoredEvidenceIsAlsoVisibleAcrossTheRound() {
        let round = ProbeContext(timeout: 10)
        let child = ProbeContext(timeout: 2, parent: round)

        child.store("mihomo-config", 7)

        var calls = 0
        let reused: Int? = round.memoized("mihomo-config") { calls += 1; return 99 }
        XCTAssertEqual(calls, 0, "已 store 的证据不应被重新求值")
        XCTAssertEqual(reused, 7)
    }
}

extension NetworkExecutionTests {
    func testLaunchFailureIsDistinctFromTimeoutAndCancellation() {
        let result = BoundedCommand.run("/nonexistent/binary", [], timeout: 1)
        XCTAssertEqual(result.outcome, .launchFailed)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertFalse(result.stderr.isEmpty, "启动失败必须带出原因，否则与「命令跑了但失败」无法区分")
    }

    func testExitCodesAreMappedForNormalAndSignalTermination() {
        let normal = BoundedCommand.run("/bin/sh", ["-c", "exit 42"], timeout: 2)
        XCTAssertEqual(normal.outcome, .exited)
        XCTAssertEqual(normal.exitCode, 42)

        let signalled = BoundedCommand.run("/bin/sh", ["-c", "kill -TERM $$"], timeout: 2)
        XCTAssertEqual(signalled.outcome, .exited)
        XCTAssertEqual(signalled.exitCode, 128 + 15, "信号退出应映射为 128+signo")
    }

    // 超时与取消的退出码是被上层用来区分「预算耗尽」与「本轮作废」的，不能只断言 outcome。
    func testTimeoutAndCancellationCarryDistinctExitCodes() {
        let timedOut = BoundedCommand.run("/bin/sleep", ["20"], timeout: 0.1)
        XCTAssertEqual(timedOut.outcome, .timedOut)
        XCTAssertEqual(timedOut.exitCode, -3)

        let context = ProbeContext(timeout: 10)
        context.cancel()
        let cancelled = BoundedCommand.run("/bin/sleep", ["20"], timeout: 5, context: context)
        XCTAssertEqual(cancelled.outcome, .cancelled, "已取消的 context 不应再启动子进程")
        XCTAssertEqual(cancelled.exitCode, -2)
        XCTAssertLessThan(cancelled.elapsed, 0.5)
    }

    // 进程组回收正是这段代码存在的理由：现有测试只验证父进程不被拖住，
    // 没有任何断言证明那个继承了管道的孙进程真的被杀掉。
    func testTimeoutKillsTheWholeProcessGroupNotJustTheDirectChild() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-pg-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        let script = "sh -c 'while :; do echo x >> \(marker.path); sleep 0.05; done' & sleep 20"
        let result = BoundedCommand.run("/bin/sh", ["-c", script], timeout: 0.5)
        XCTAssertEqual(result.outcome, .timedOut)

        // 给残留的孙进程留出继续写入的时间窗；若进程组没被收掉，文件会持续增长。
        Thread.sleep(forTimeInterval: 0.5)
        let afterKill = (try? Data(contentsOf: marker))?.count ?? 0
        Thread.sleep(forTimeInterval: 0.5)
        let later = (try? Data(contentsOf: marker))?.count ?? 0

        XCTAssertEqual(later, afterKill, "孙进程仍在写入，说明进程组没有被回收")
    }
}

extension LatestEvaluationTests {
    // cancel() 是公开方法，此前全仓零调用、零测试。
    func testCancelStopsPendingWorkAndBumpsGeneration() {
        let queue = DispatchQueue(label: "cancel-test")
        let scheduler = LatestEvaluation(queue: queue)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pendingRan = NSLock()
        var pendingDidRun = false

        scheduler.submit(timeout: 5) { _ in
            started.signal()
            release.wait()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        scheduler.submit(timeout: 5) { _ in
            pendingRan.lock(); pendingDidRun = true; pendingRan.unlock()
        }
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.cancel()
        XCTAssertEqual(scheduler.pendingCount, 0, "cancel 必须清空待处理请求")
        release.signal()

        let drained = XCTestExpectation(description: "queue drained")
        queue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        pendingRan.lock(); let ran = pendingDidRun; pendingRan.unlock()
        XCTAssertFalse(ran, "被取消的待处理请求不应再执行")
    }

    // 非 superseding 提交只替换 pending，不推进 generation——这条语义此前零覆盖，
    // 而它决定了「重复的相同通知」不会把正在进行的评估作废。
    func testNonSupersedingSubmitReplacesPendingWithoutBumpingGeneration() {
        let queue = DispatchQueue(label: "pending-test")
        let scheduler = LatestEvaluation(queue: queue)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let seen = NSLock()
        var generations: [UInt64] = []

        scheduler.submit(timeout: 5) { context in
            seen.lock(); generations.append(context.generation); seen.unlock()
            started.signal()
            release.wait()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        scheduler.submit(timeout: 5) { _ in XCTFail("第一个 pending 应被后来者替换") }
        scheduler.submit(timeout: 5) { context in
            seen.lock(); generations.append(context.generation); seen.unlock()
        }
        XCTAssertEqual(scheduler.pendingCount, 1, "最多保留一个待处理请求")

        release.signal()
        let drained = XCTestExpectation(description: "queue drained")
        queue.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)

        seen.lock(); let observed = generations; seen.unlock()
        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(observed[0], observed[1], "非 superseding 提交不应推进 generation")
        XCTAssertEqual(scheduler.pendingCount, 0, "排空后待处理数应归零")
    }
}
