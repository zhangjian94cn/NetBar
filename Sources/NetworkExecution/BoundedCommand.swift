import Foundation
import Darwin

/// A cancellation/deadline shared by all work in one recovery generation.
public final class ProbeContext: @unchecked Sendable {
    public let generation: UInt64
    public let recoveryID: String
    public let deadline: TimeInterval
    private let lock = NSLock()
    private let parent: ProbeContext?
    private let cacheLock = NSRecursiveLock()
    private var cache: [String: Any] = [:]
    private var cancelled = false
    public static var monotonicNow: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public init(generation: UInt64 = 0, timeout: TimeInterval, recoveryID: String = UUID().uuidString, parent: ProbeContext? = nil) {
        self.parent = parent
        self.generation = generation
        self.recoveryID = recoveryID
        self.deadline = min(Self.monotonicNow + max(0, timeout), parent?.deadline ?? .infinity)
    }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || parent?.isCancelled == true }
    /// Evidence is reused per generation, so the memo lives on the round context, not on the
    /// short-lived child a single probe creates for its own budget.  `memoized` and `store`
    /// enforce this themselves — callers must not have to remember to write `.root`, which is
    /// exactly the inconsistency that let one call site share evidence while two others did not.
    public var root: ProbeContext { parent?.root ?? self }
    public var remaining: TimeInterval { max(0, deadline - Self.monotonicNow) }
    public var isStopped: Bool { isCancelled || remaining <= 0 }
    public func memoized<T>(_ key: String, _ make: () -> T) -> T {
        let owner = root
        owner.cacheLock.lock(); defer { owner.cacheLock.unlock() }
        // Presence must be tested before the cast: for an optional `T`, `cache[key] as? T`
        // also succeeds on a *missing* key and yields nil, which would skip `make()`
        // entirely and memoize "no evidence" forever.  `as Any` keeps a cached nil stored
        // instead of deleting the key.
        if let entry = owner.cache[key], let cached = entry as? T { return cached }
        let value = make(); owner.cache[key] = value as Any; return value
    }
    /// Records evidence worth reusing this round.  Callers use this instead of `memoized`
    /// when a failed read must stay retryable rather than becoming the round's verdict.
    public func store<T>(_ key: String, _ value: T) {
        let owner = root
        owner.cacheLock.lock(); defer { owner.cacheLock.unlock() }
        owner.cache[key] = value as Any
    }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    // The legacy synchronous policy passes its scope through nested adapters.
    // Concurrent branches must explicitly install the same scope using withValue.
    public static var current: ProbeContext? { Thread.current.threadDictionary["NetBar.ProbeContext"] as? ProbeContext }
    public static func install(_ context: ProbeContext?) {
        Thread.current.threadDictionary["NetBar.ProbeContext"] = context
    }
    public static func withValue<T>(_ context: ProbeContext?, _ body: () throws -> T) rethrows -> T {
        let previous = current
        Thread.current.threadDictionary["NetBar.ProbeContext"] = context
        defer { Thread.current.threadDictionary["NetBar.ProbeContext"] = previous }
        return try body()
    }
}

public enum CommandOutcome: String, Sendable { case exited, timedOut, cancelled, launchFailed }
public struct BoundedCommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let outcome: CommandOutcome
    public let elapsed: TimeInterval
    public let outputTruncated: Bool
}

/// Owns a process group. Reads both pipes without blocking and always reaps its child.
public enum BoundedCommand {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2,
                           context: ProbeContext? = ProbeContext.current,
                           outputLimit: Int = 1_048_576) -> BoundedCommandResult {
        let started = ProbeContext.monotonicNow
        let deadline = min(started + max(0, timeout), context?.deadline ?? .infinity)
        func result(_ code: Int32, _ out: Data, _ err: Data, _ outcome: CommandOutcome, _ truncated: Bool = false) -> BoundedCommandResult {
            .init(exitCode: code, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self),
                  outcome: outcome, elapsed: ProbeContext.monotonicNow - started, outputTruncated: truncated)
        }
        if context?.isCancelled == true { return result(-2, Data(), Data(), .cancelled) }
        if deadline <= started { return result(-3, Data(), Data(), .timedOut) }
        var outFD: [Int32] = [0, 0], errFD: [Int32] = [0, 0]
        guard pipe(&outFD) == 0 else { return result(-1, Data(), Data("pipe failed".utf8), .launchFailed) }
        guard pipe(&errFD) == 0 else {
            close(outFD[0]); close(outFD[1]); return result(-1, Data(), Data("pipe failed".utf8), .launchFailed)
        }
        var actions: posix_spawn_file_actions_t?
        var attrs: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attrs)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errFD[1], STDERR_FILENO)
        for fd in outFD + errFD { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { if let pointer = $0 { free(pointer) } } }
        var pid: pid_t = 0
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { if let pointer = $0 { free(pointer) } } }
        let error = argv.withUnsafeBufferPointer { arguments in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attrs, arguments.baseAddress!, env.baseAddress!)
            }
        }
        close(outFD[1]); close(errFD[1])
        defer { close(outFD[0]); close(errFD[0]) }
        guard error == 0 else { return result(-1, Data(), Data(String(cString: strerror(error)).utf8), .launchFailed) }
        for fd in [outFD[0], errFD[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        var out = Data(), err = Data(), truncated = false
        var status: Int32 = 0
        var exited = false
        var outcome = CommandOutcome.exited
        var stoppedAt: TimeInterval?
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain(_ fd: Int32, into data: inout Data) {
            // Limit work per pass, even if a producer never stops writing.
            for _ in 0..<32 {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                let kept = min(count, max(0, outputLimit - data.count))
                data.append(contentsOf: buffer.prefix(kept))
                if kept < count { truncated = true }
            }
        }
        while true {
            drain(outFD[0], into: &out); drain(errFD[0], into: &err)
            let now = ProbeContext.monotonicNow
            if stoppedAt == nil && (context?.isCancelled == true || now >= deadline) {
                outcome = context?.isCancelled == true ? .cancelled : .timedOut
                stoppedAt = now
                kill(-pid, SIGTERM)
            }
            if let stoppedAt, now - stoppedAt >= 0.2 { kill(-pid, SIGKILL) }
            if !exited { exited = waitpid(pid, &status, WNOHANG) == pid }
            if exited {
                // Clean up children inheriting the pipes too; never wait for EOF.
                kill(-pid, SIGKILL)
                drain(outFD[0], into: &out); drain(errFD[0], into: &err)
                break
            }
            var pollFDs = [pollfd(fd: outFD[0], events: Int16(POLLIN), revents: 0), pollfd(fd: errFD[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&pollFDs, 2, 20)
        }
        let code: Int32 = outcome == .cancelled ? -2 : outcome == .timedOut ? -3 : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        return result(code, out, err, outcome, truncated)
    }
}
