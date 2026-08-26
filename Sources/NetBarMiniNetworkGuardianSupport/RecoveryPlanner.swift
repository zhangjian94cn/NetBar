import Foundation

public struct MiniGuardianRecoveryInput: Equatable {
    public let carrierActive: Bool
    public let preferencesMatch: Bool
    public let sharingConfigured: Bool
    public let addressReady: Bool
    public let routeReady: Bool
    public let sharingRunning: Bool
    public let upstreamReachable: Bool
    public let pendingRepairVerification: Bool
    public let retryRemaining: TimeInterval?
    public let addressWaitElapsed: TimeInterval?
    public let sharingWaitElapsed: TimeInterval?
    public let healthyElapsed: TimeInterval?

    public init(
        carrierActive: Bool,
        preferencesMatch: Bool,
        sharingConfigured: Bool,
        addressReady: Bool,
        routeReady: Bool,
        sharingRunning: Bool,
        upstreamReachable: Bool,
        pendingRepairVerification: Bool,
        retryRemaining: TimeInterval?,
        addressWaitElapsed: TimeInterval?,
        sharingWaitElapsed: TimeInterval?,
        healthyElapsed: TimeInterval?
    ) {
        self.carrierActive = carrierActive
        self.preferencesMatch = preferencesMatch
        self.sharingConfigured = sharingConfigured
        self.addressReady = addressReady
        self.routeReady = routeReady
        self.sharingRunning = sharingRunning
        self.upstreamReachable = upstreamReachable
        self.pendingRepairVerification = pendingRepairVerification
        self.retryRemaining = retryRemaining
        self.addressWaitElapsed = addressWaitElapsed
        self.sharingWaitElapsed = sharingWaitElapsed
        self.healthyElapsed = healthyElapsed
    }
}

public enum MiniGuardianRecoveryDecision: Equatable {
    case carrierDown
    case configurationDrift(String)
    case addressRecovering(TimeInterval)
    case reapplyAddress
    case sharingRecovering(TimeInterval)
    case restartSharing
    case readyStabilizing(TimeInterval)
    case ready(resetBackoff: Bool)
    case recoveryBackoff(TimeInterval)
    case repairFailed
}

public enum MiniGuardianRecoveryPlanner {
    public static func decide(_ input: MiniGuardianRecoveryInput) -> MiniGuardianRecoveryDecision {
        guard input.carrierActive else { return .carrierDown }
        guard input.preferencesMatch else {
            return .configurationDrift("en0 manual configuration differs from NetBar profile")
        }
        guard input.sharingConfigured else {
            return .configurationDrift("Internet Sharing must use en0 and include bridge0")
        }

        let healthy = input.addressReady && input.routeReady &&
            input.sharingRunning && input.upstreamReachable
        if healthy {
            let elapsed = input.healthyElapsed ?? 0
            if elapsed < 30 {
                return .readyStabilizing(30 - elapsed)
            }
            return .ready(resetBackoff: elapsed >= 60)
        }

        if input.pendingRepairVerification { return .repairFailed }
        if let remaining = input.retryRemaining, remaining > 0 {
            return .recoveryBackoff(remaining)
        }
        if !input.addressReady || !input.routeReady {
            let elapsed = input.addressWaitElapsed ?? 0
            return elapsed < 15 ? .addressRecovering(15 - elapsed) : .reapplyAddress
        }
        if !input.sharingRunning || !input.upstreamReachable {
            let elapsed = input.sharingWaitElapsed ?? 0
            return elapsed < 15 ? .sharingRecovering(15 - elapsed) : .restartSharing
        }

        return .repairFailed
    }
}

public enum NetworkServiceOrderParser {
    public static func serviceName(forDevice device: String, in output: String) -> String? {
        var pendingService: String?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.first == "(",
               let close = line.firstIndex(of: ")"),
               let ordinal = Int(line[line.index(after: line.startIndex)..<close]),
               ordinal > 0 {
                var name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("*") {
                    name.removeFirst()
                    name = name.trimmingCharacters(in: .whitespaces)
                }
                pendingService = name.isEmpty ? nil : name
                continue
            }
            if line.contains("Device: \(device))"), let pendingService {
                return pendingService
            }
        }
        return nil
    }
}
