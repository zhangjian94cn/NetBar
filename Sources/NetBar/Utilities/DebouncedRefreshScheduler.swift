import Foundation

final class DebouncedRefreshScheduler {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval = 3, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ action: @escaping () -> Void) {
        workItem?.cancel()
        let nextItem = DispatchWorkItem(block: action)
        workItem = nextItem
        queue.asyncAfter(deadline: .now() + delay, execute: nextItem)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
