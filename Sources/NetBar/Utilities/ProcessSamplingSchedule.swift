import Foundation

/// Main-thread admission and cooldown for the expensive process sampler.
/// Times are monotonic; visibility and preference changes never bypass a failure cooldown.
struct ProcessSamplingSchedule {
    private(set) var isRunning = false
    private(set) var isSampling = false
    private(set) var generation: UInt64 = 0
    private(set) var failures = 0
    private var completedAt: TimeInterval?
    var isVisible = false
    var requestedInterval: TimeInterval = 2

    var interval: TimeInterval {
        let requested = requestedInterval.isFinite ? requestedInterval : 2
        return max(isVisible ? 2 : 10, requested)
    }

    var delay: TimeInterval {
        failures == 0 ? interval : max(interval, min(300, 15 * pow(2, Double(failures - 1))))
    }

    mutating func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        completedAt = nil
        failures = 0
    }

    mutating func stop() {
        isRunning = false
        generation &+= 1
        // A running worker retains the slot until it completes, even across restart.
    }

    func waitTime(now: TimeInterval) -> TimeInterval {
        guard let completedAt else { return 0 }
        return max(0, completedAt + delay - now)
    }

    mutating func begin(now: TimeInterval) -> UInt64? {
        guard isRunning, !isSampling, waitTime(now: now) <= 0 else { return nil }
        isSampling = true
        return generation
    }

    @discardableResult
    mutating func complete(generation: UInt64, succeeded: Bool, now: TimeInterval) -> Bool {
        isSampling = false
        guard isRunning, self.generation == generation else { return false }
        completedAt = now
        failures = succeeded ? 0 : min(failures + 1, 6)
        return true
    }
}
