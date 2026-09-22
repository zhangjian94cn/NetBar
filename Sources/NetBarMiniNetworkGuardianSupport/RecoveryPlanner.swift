import Foundation

/// Everything the Guardian knows about whether the Mac mini can serve as the Thunderbolt egress.
///
/// These are *serving* facts.  Hotspot AP state and downstream reports are deliberately absent:
/// they used to feed a "restart Apple sharing" branch that never restored sharing and twice left
/// it permanently stopped.  `upstreamReachable` is the Mini's own bound HTTPS probe; it gates
/// `ready` but is never a reason to treat sharing as broken.
public struct MiniGuardianServingFacts: Equatable {
    public let carrierActive: Bool
    public let preferencesMatch: Bool
    public let sharingConfigured: Bool
    public let sharingIntentEnabled: Bool
    public let dhcpServerEnabled: Bool
    public let managementAddressReady: Bool
    public let managementAliasRestorable: Bool
    public let bridgeUsesDHCP: Bool
    public let sharedAddressReady: Bool
    public let addressReady: Bool
    public let routeReady: Bool
    public let sharingRunning: Bool
    public let forwardingEnabled: Bool
    public let upstreamReachable: Bool

    public init(
        carrierActive: Bool,
        preferencesMatch: Bool,
        sharingConfigured: Bool,
        sharingIntentEnabled: Bool,
        dhcpServerEnabled: Bool,
        managementAddressReady: Bool,
        managementAliasRestorable: Bool,
        bridgeUsesDHCP: Bool,
        sharedAddressReady: Bool,
        addressReady: Bool,
        routeReady: Bool,
        sharingRunning: Bool,
        forwardingEnabled: Bool,
        upstreamReachable: Bool
    ) {
        self.carrierActive = carrierActive
        self.preferencesMatch = preferencesMatch
        self.sharingConfigured = sharingConfigured
        self.sharingIntentEnabled = sharingIntentEnabled
        self.dhcpServerEnabled = dhcpServerEnabled
        self.managementAddressReady = managementAddressReady
        self.managementAliasRestorable = managementAliasRestorable
        self.bridgeUsesDHCP = bridgeUsesDHCP
        self.sharedAddressReady = sharedAddressReady
        self.addressReady = addressReady
        self.routeReady = routeReady
        self.sharingRunning = sharingRunning
        self.forwardingEnabled = forwardingEnabled
        self.upstreamReachable = upstreamReachable
    }
}

/// The Guardian's verdict.  Every case is a *state*; none is an action on Apple's daemon.
public enum MiniGuardianRecoveryDecision: Equatable {
    case carrierDown
    case configurationDrift(String)
    /// The alias was missing and has just been (re)written; verify on the next round.
    case managementLinkRecovering
    case addressRecovering
    /// Sharing is switched on but not serving; Apple is expected to rebuild it within the grace period.
    case sharingRecovering(reason: String, remaining: TimeInterval)
    case sharingManualPending(String)
    /// Everything local serves, but the Mini's own bound HTTPS probe failed.  Not a sharing fault,
    /// so it never counts towards the manual-pending window.
    case upstreamUnreachable
    case readyStabilizing(TimeInterval)
    case ready
}

public enum MiniGuardianRecoveryPlanner {
    /// Apple's daemon idles out 60 s after a teardown and rebuilt sharing in ~20 s on 2026-09-14;
    /// a not-serving condition older than this has stopped being a transient.
    public static let sharingRecoveryGracePeriod: TimeInterval = 90
    public static let readyStabilization: TimeInterval = 30
    public static let manualRecoveryHint = "toggle Internet Sharing off and on in System Settings"

    public static func appleDHCPEnabled(from value: Any?) -> Bool {
        if let interfaces = value as? [String] {
            return interfaces.contains("bridge0")
        }
        if let enabled = value as? Bool { return enabled }
        if let enabled = value as? NSNumber { return enabled.intValue == 1 }
        return false
    }

    public static func decide(
        _ facts: MiniGuardianServingFacts,
        sharingWaitElapsed: TimeInterval?,
        healthyElapsed: TimeInterval?
    ) -> MiniGuardianRecoveryDecision {
        guard facts.bridgeUsesDHCP else {
            return .configurationDrift("Thunderbolt Bridge must use DHCP; fixed IPv4 conflicts with Internet Sharing")
        }
        guard facts.managementAddressReady else {
            return facts.managementAliasRestorable
                ? .managementLinkRecovering
                : .configurationDrift("management subnet conflicts or bridge identity unavailable")
        }
        guard facts.carrierActive else { return .carrierDown }
        guard facts.preferencesMatch else {
            return .configurationDrift("en0 manual configuration differs from NetBar profile")
        }
        guard facts.sharingConfigured else {
            return .configurationDrift("Internet Sharing must use en0 and include Wi-Fi plus bridge0")
        }
        guard facts.sharingIntentEnabled else {
            return .sharingManualPending("enable Internet Sharing in System Settings")
        }
        guard facts.addressReady, facts.routeReady else { return .addressRecovering }

        let missing = notServingFacts(facts)
        if !missing.isEmpty {
            let reason = missing.joined(separator: "; ")
            let waited = sharingWaitElapsed ?? 0
            if waited < sharingRecoveryGracePeriod {
                return .sharingRecovering(reason: reason, remaining: sharingRecoveryGracePeriod - waited)
            }
            return .sharingManualPending("\(reason); \(manualRecoveryHint)")
        }
        guard facts.upstreamReachable else { return .upstreamUnreachable }

        let elapsed = healthyElapsed ?? 0
        return elapsed < readyStabilization ? .readyStabilizing(readyStabilization - elapsed) : .ready
    }

    /// The serving facts that are false, in the words the status file and the MacBook card show.
    public static func notServingFacts(_ facts: MiniGuardianServingFacts) -> [String] {
        var missing: [String] = []
        if !facts.dhcpServerEnabled { missing.append("Apple DHCP is disabled") }
        if !facts.sharingRunning { missing.append("InternetSharing is not running") }
        if !facts.forwardingEnabled { missing.append("kernel forwarding is disabled") }
        if !facts.sharedAddressReady { missing.append("no shared IPv4 on bridge0") }
        return missing
    }

    /// The single definition of "every fact `decide` needs for `ready` is true".  The Guardian
    /// evaluates this standalone to drive `healthySince`, which is fed back in as `healthyElapsed`;
    /// `decide` reaches its stabilization branch under exactly this condition.
    public static func isFullyHealthy(_ facts: MiniGuardianServingFacts) -> Bool {
        facts.bridgeUsesDHCP && facts.managementAddressReady && facts.carrierActive &&
            facts.preferencesMatch && facts.sharingConfigured && facts.sharingIntentEnabled &&
            facts.addressReady && facts.routeReady && notServingFacts(facts).isEmpty &&
            facts.upstreamReachable
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
