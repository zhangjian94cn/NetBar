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
        guard input.bridgeUsesDHCP else {
            return .configurationDrift("Thunderbolt Bridge must use DHCP; fixed IPv4 conflicts with Internet Sharing")
        }
        guard input.managementAddressReady else {
            return input.pendingRepairVerification ? .repairFailed : .reapplyManagementAlias
        }
        guard input.carrierActive else { return .carrierDown }
        guard input.preferencesMatch else {
            return .configurationDrift("en0 manual configuration differs from NetBar profile")
        }
        guard input.sharingConfigured else {
            return .configurationDrift("Internet Sharing must use en0 and include Wi-Fi plus bridge0")
        }
        guard input.sharingIntentEnabled else { return .sharingManualPending }
        guard input.dhcpServerEnabled else { return .sharingManualPending }


        if input.downstreamEgressFailureReported {
            if let remaining = input.retryRemaining, remaining > 0 {
                return .recoveryBackoff(remaining)
            }
            return .restartSharing
        }

        if isFullyHealthy(input) {
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

        // Unreachable: arriving here requires every fact checked by the two blocks above to be
        // true, which is exactly `isFullyHealthy` and would have returned already.  Kept as a
        // benign fallback rather than a trap — this runs as root on the Mini, where crashing
        // is strictly worse than reporting a repair failure.
        return .repairFailed
    }

    /// The single definition of "every observed fact is healthy".
    ///
    /// `decide` reaches its health check only after guards have already established carrier,
    /// management address, bridge DHCP and the Apple DHCP server, so re-checking them there is
    /// redundant but harmless.  Guardian evaluates this standalone to drive `healthySince`,
    /// with no guards in front of it, so it must check all of them.  Both callers now share one
    /// expression: the previous arrangement was only equivalent as long as nobody reordered
    /// `decide`'s guards, and nothing tested that.
    public static func isFullyHealthy(_ input: MiniGuardianRecoveryInput) -> Bool {
        isFullyHealthy(
            carrierActive: input.carrierActive,
            managementAddressReady: input.managementAddressReady,
            bridgeUsesDHCP: input.bridgeUsesDHCP,
            dhcpServerEnabled: input.dhcpServerEnabled,
            addressReady: input.addressReady,
            routeReady: input.routeReady,
            sharedAddressReady: input.sharedAddressReady,
            hotspotAPActive: input.hotspotAPActive,
            sharingRunning: input.sharingRunning,
            forwardingEnabled: input.forwardingEnabled,
            upstreamReachable: input.upstreamReachable
        )
    }

    public static func isFullyHealthy(
        carrierActive: Bool,
        managementAddressReady: Bool,
        bridgeUsesDHCP: Bool,
        dhcpServerEnabled: Bool,
        addressReady: Bool,
        routeReady: Bool,
        sharedAddressReady: Bool,
        hotspotAPActive: Bool,
        sharingRunning: Bool,
        forwardingEnabled: Bool,
        upstreamReachable: Bool
    ) -> Bool {
        carrierActive && managementAddressReady && bridgeUsesDHCP && dhcpServerEnabled &&
            addressReady && routeReady && sharedAddressReady && hotspotAPActive &&
            sharingRunning && forwardingEnabled && upstreamReachable
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

/// Guardian 的接口事实解析。这些是纯函数，此前写在 executable target 的 main.swift 里，
/// 测试 target 不依赖它，因此唯一的「覆盖」是对源码文本做 grep。仓库里已有现成的下沉范式
/// （bootpdDHCPIsEnabled → MiniGuardianRecoveryPlanner.appleDHCPEnabled，已下沉且有测）。
public enum GuardianInterfaceFacts {
    /// 管理别名是否可以安全地写回 bridge0。
    ///
    /// 两个条件：bridge0 必须是我们认识的那座桥（`ifconfig` 中带 `member:` 行，避免把别名写到
    /// 一个同名但无成员的空桥上）；管理网段不得已经出现在**其他**接口上（地址冲突时宁可不写）。
    ///
    /// `managementSubnetPrefix` 由调用方从 profile 推导而非写死——原实现硬编码了
    /// `"10.254.254."`，profile 换网段时这道保护会静默失效。
    public static func managementAliasCanBeRestored(
        ifconfigOutput: String,
        managementSubnetPrefix: String,
        bridgeDevice: String = "bridge0"
    ) -> Bool {
        var device = ""
        var knownBridge = false
        for line in ifconfigOutput.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t"), let name = line.split(separator: ":").first { device = String(name) }
            if device == bridgeDevice, line.contains("member:") { knownBridge = true }
            if device != bridgeDevice, line.contains("inet \(managementSubnetPrefix)") { return false }
        }
        return knownBridge
    }

    /// 从管理地址推导网段前缀，例如 `10.254.254.1` → `10.254.254.`。
    public static func managementSubnetPrefix(forAddress address: String) -> String {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return address }
        return parts.dropLast().joined(separator: ".") + "."
    }

    /// Apple 互联网共享的开关意图。
    ///
    /// 只接受 Bool 与 Int 两种编码——与 `appleDHCPEnabled` 不同，后者要处理 `[String]`，
    /// 因为 bootpd 的 `dhcp_enabled` 可以是接口名数组；NAT 的 `Enabled` 不是这种形状。
    public static func sharingIntentIsEnabled(natPlist object: [String: Any]?) -> Bool {
        guard let nat = object?["NAT"] as? [String: Any] else { return false }
        if let enabled = nat["Enabled"] as? Bool { return enabled }
        if let enabled = nat["Enabled"] as? Int { return enabled == 1 }
        return false
    }
}
