import Foundation

public enum NativeSharingProcessIdentity {
    public static func pid(fromLaunchctlPrint output: String) -> Int32? {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains("state = running"),
              lines.contains("program = /usr/libexec/InternetSharing"),
              let pidLine = lines.first(where: { $0.hasPrefix("pid = ") }) else {
            return nil
        }
        let value = String(pidLine.dropFirst("pid = ".count))
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let pid = Int32(value), pid > 1 else {
            return nil
        }
        return pid
    }

    public static func isStoppedNativeService(launchctlPrint output: String) -> Bool {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.contains("state = not running") &&
            lines.contains("program = /usr/libexec/InternetSharing") &&
            !lines.contains(where: { $0.hasPrefix("pid = ") })
    }
}

public enum GuardianPersistedRecoveryMigration {
    public static func shouldResetBackoff(lastError: String?) -> Bool {
        guard let lastError else { return false }
        return lastError.contains("Could not kickstart service") &&
            lastError.contains("System Integrity Protection")
    }
}

public enum GuardianEvaluationCadence {
    public static func duringRecoveryBackoff(remaining: TimeInterval) -> TimeInterval {
        min(15, max(1, remaining))
    }
}

public struct MiniGuardianRecoveryInput: Equatable {
    public let carrierActive: Bool
    public let preferencesMatch: Bool
    public let sharingConfigured: Bool
    public let sharingIntentEnabled: Bool
    public let dhcpServerEnabled: Bool
    public let managementAddressReady: Bool
    public let bridgeUsesDHCP: Bool
    public let sharedAddressReady: Bool
    public let hotspotAPActive: Bool
    public let addressReady: Bool
    public let routeReady: Bool
    public let sharingRunning: Bool
    public let forwardingEnabled: Bool
    public let downstreamEgressFailureReported: Bool
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
        sharingIntentEnabled: Bool,
        dhcpServerEnabled: Bool,
        managementAddressReady: Bool,
        bridgeUsesDHCP: Bool,
        sharedAddressReady: Bool,
        hotspotAPActive: Bool,
        addressReady: Bool,
        routeReady: Bool,
        sharingRunning: Bool,
        forwardingEnabled: Bool,
        downstreamEgressFailureReported: Bool,
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
        self.sharingIntentEnabled = sharingIntentEnabled
        self.dhcpServerEnabled = dhcpServerEnabled
        self.managementAddressReady = managementAddressReady
        self.bridgeUsesDHCP = bridgeUsesDHCP
        self.sharedAddressReady = sharedAddressReady
        self.hotspotAPActive = hotspotAPActive
        self.addressReady = addressReady
        self.routeReady = routeReady
        self.sharingRunning = sharingRunning
        self.forwardingEnabled = forwardingEnabled
        self.downstreamEgressFailureReported = downstreamEgressFailureReported
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
    case sharingManualPending
    case reapplyManagementAlias
    case addressRecovering(TimeInterval)
    case sharingRecovering(TimeInterval)
    case restartSharing
    case readyStabilizing(TimeInterval)
    case ready(resetBackoff: Bool)
    case recoveryBackoff(TimeInterval)
    case repairFailed
}

public enum MiniGuardianRecoveryPlanner {
    public static func appleDHCPEnabled(from value: Any?) -> Bool {
        if let interfaces = value as? [String] {
            return interfaces.contains("bridge0")
        }
        if let enabled = value as? Bool { return enabled }
        if let enabled = value as? NSNumber { return enabled.intValue == 1 }
        return false
    }

    public static func decide(_ input: MiniGuardianRecoveryInput) -> MiniGuardianRecoveryDecision {
        guard input.carrierActive else { return .carrierDown }
        guard input.preferencesMatch else {
            return .configurationDrift("en0 manual configuration differs from NetBar profile")
        }
        guard input.sharingConfigured else {
            return .configurationDrift("Internet Sharing must use en0 and include Wi-Fi plus bridge0")
        }
        guard input.sharingIntentEnabled else { return .sharingManualPending }
        guard input.dhcpServerEnabled else { return .sharingManualPending }
        guard input.bridgeUsesDHCP else {
            return .configurationDrift("Thunderbolt Bridge must use DHCP; fixed IPv4 conflicts with Internet Sharing")
        }
        guard input.managementAddressReady else {
            return input.pendingRepairVerification ? .repairFailed : .reapplyManagementAlias
        }

        if input.downstreamEgressFailureReported {
            if let remaining = input.retryRemaining, remaining > 0 {
                return .recoveryBackoff(remaining)
            }
            return .restartSharing
        }

        let healthy = input.addressReady && input.routeReady && input.sharedAddressReady && input.hotspotAPActive &&
            input.sharingRunning && input.forwardingEnabled && input.upstreamReachable
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
            return elapsed < 15 ? .addressRecovering(15 - elapsed) : .repairFailed
        }
        if !input.sharedAddressReady || !input.hotspotAPActive || !input.sharingRunning ||
            !input.forwardingEnabled || !input.upstreamReachable {
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
