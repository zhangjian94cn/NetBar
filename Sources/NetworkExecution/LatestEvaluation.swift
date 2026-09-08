import Foundation

/// Coalesces before dispatch. There is at most one queued/running body and one replacement.
public final class LatestEvaluation: @unchecked Sendable {
    public typealias Work = (ProbeContext) -> Void
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var active: ProbeContext?
    private var lastContext: ProbeContext?
    private var pending: (ProbeContext, Work)?
    private var generation: UInt64 = 0
    public init(queue: DispatchQueue) { self.queue = queue }
    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending == nil ? 0 : 1 }
    public func submit(timeout: TimeInterval, superseding: Bool = false, work: @escaping Work) {
        lock.lock()
        if superseding { generation &+= 1; active?.cancel(); lastContext?.cancel() }
        let context = ProbeContext(generation: generation, timeout: timeout)
        if active != nil {
            pending?.0.cancel()
            pending = (context, work)
            lock.unlock()
            return
        }
        active = context
        lastContext = context
        lock.unlock()
        dispatch(context, work)
    }
    public func cancel() {
        lock.lock(); generation &+= 1; active?.cancel(); lastContext?.cancel(); pending?.0.cancel(); pending = nil; lock.unlock()
    }
    private func dispatch(_ context: ProbeContext, _ work: @escaping Work) {
        queue.async { [self] in
            if !context.isStopped { ProbeContext.withValue(context) { work(context) } }
            lock.lock()
            let next = pending
            pending = nil
            active = next?.0
            if let next { lastContext = next.0 }
            lock.unlock()
            if let next { dispatch(next.0, next.1) }
        }
    }
}
