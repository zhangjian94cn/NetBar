import Foundation

struct MacMiniLinkProfile: Codable, Equatable {
    let managementLocalAddress: String
    let managementMiniAddress: String
    let managementSubnetMask: String
    let sshHostKeyAlias: String
    let miniUpstreamDevice: String
    let miniUpstreamAddress: String
    let miniUpstreamSubnetMask: String
    let miniUpstreamRouter: String
    let miniSSHUser: String
    let miniBonjourHost: String
    let probeTargets: [String]
    let httpsProbeTargets: [String]

    static let defaults = MacMiniLinkProfile(
        managementLocalAddress: "10.254.254.2",
        managementMiniAddress: "10.254.254.1",
        managementSubnetMask: "255.255.255.252",
        sshHostKeyAlias: "192.168.2.1",
        miniUpstreamDevice: "en0",
        miniUpstreamAddress: "10.32.143.206",
        miniUpstreamSubnetMask: "255.255.255.0",
        miniUpstreamRouter: "10.32.143.1",
        miniSSHUser: "zhangjian",
        miniBonjourHost: "zhangjiandemac-mini.local",
        probeTargets: ["1.1.1.1", "114.114.114.114"],
        httpsProbeTargets: [
            "https://www.apple.com/library/test/success.html",
            "https://cp.cloudflare.com/generate_204"
        ]
    )

    static let bundled: MacMiniLinkProfile = {
        guard let url = NetBarResourceBundle.current.url(
            forResource: "MacMiniLinkProfile",
            withExtension: "plist",
            subdirectory: "MiniLinkHelper"
        ),
        let data = try? Data(contentsOf: url),
        let profile = try? PropertyListDecoder().decode(MacMiniLinkProfile.self, from: data) else {
            return .defaults
        }
        return profile
    }()

    var fixedHostKeyAlias: String { sshHostKeyAlias }

    static func isLinkLocalIPv4(_ address: String?) -> Bool {
        address?.hasPrefix("169.254.") == true
    }
}

enum MacMiniGatewayState: String, Codable, Equatable {
    case ready
    case carrierDown
    case addressRecovering
    case sharingRecovering
    case readyStabilizing
    case configurationDrift
    case recoveryBackoff
    case routeFlapping
    case boundEgressUnavailable
    case remoteStatusUnavailable
    case remoteEvidenceConflict
    case sharingForwardingUnavailable
    case sharingManualPending
    case managementLinkRecovering
    case dhcpLeaseRecovering
    case hotspotClientUnverified
    case upstreamUnreachable
    case guardianStale
    case unknown

    /// The Guardian ships separately from the app.  A verdict this build does not know must not
    /// throw away the whole helper status (that used to degrade to "无法读取 Mac mini 状态"); it is
    /// simply an unknown verdict, which never qualifies anything.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MacMiniGatewayState(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .ready:
            return "Mac mini 上游正常"
        case .carrierDown:
            return "Mac mini 以太网无载波"
        case .addressRecovering:
            return "Mac mini 正在恢复地址"
        case .sharingRecovering:
            return "Mac mini 正在恢复共享"
        case .readyStabilizing:
            return "Mac mini 上游正在稳定"
        case .configurationDrift:
            return "Mac mini 上游配置已变化"
        case .recoveryBackoff:
            return "Mac mini Guardian 观测未完成"
        case .routeFlapping:
            return "Mac mini 上游反复抖动"
        case .boundEgressUnavailable:
            return "Mac mini 出口探测失败"
        case .remoteStatusUnavailable:
            return "无法读取 Mac mini 状态"
        case .remoteEvidenceConflict:
            return "Mac mini 共享状态证据冲突"
        case .sharingForwardingUnavailable:
            return "Mac mini 共享转发未就绪"
        case .sharingManualPending:
            return "请在 Mac mini 系统设置中重新开启互联网共享"
        case .managementLinkRecovering:
            return "Mac mini 管理链路正在恢复"
        case .dhcpLeaseRecovering:
            return "雷雳共享地址正在获取"
        case .hotspotClientUnverified:
            return "热点已配置，客户端出口未验证"
        case .upstreamUnreachable:
            return "Mac mini 上游不可达"
        case .guardianStale:
            return "Mac mini Guardian 状态过期"
        case .unknown:
            return "Mac mini 上游待检测"
        }
    }

    var isReady: Bool { self == .ready }
}

struct MacMiniGuardianStatus: Codable, Equatable {
    let state: MacMiniGatewayState
    let observedAt: String?
    let generation: UInt64
    let lastTransition: String?
    let lastCarrierChange: String?
    let lastAction: String?
    let lastError: String?
    let carrierActive: Bool
    let addressReady: Bool
    let routeReady: Bool
    let sharingRunning: Bool
    let forwardingEnabled: Bool
    let sharingConfigured: Bool
    let upstreamReachable: Bool
    let nextRetryAt: String?
    let managementAddressReady: Bool?
    let bridgeUsesDHCP: Bool?
    let sharingIntentEnabled: Bool?
    var dhcpServerEnabled: Bool? = nil
    let hotspotAPConfigured: Bool?
    var hotspotAPActive: Bool? = nil
    var hotspotClientObserved: Bool? = nil
    var guardianVersion: Int? = nil
}

struct MacMiniHelperStatus: Codable, Equatable {
    let protocolVersion: Int
    let configured: Bool
    let serviceIPv4: String?
    let gatewayIPv4: String?
    let managementIPv4: String?
    let managementPeerIPv4: String?
    let bridgeUsesDHCP: Bool
    let sharingIntentEnabled: Bool
    var dhcpServerEnabled: Bool? = nil
    let hotspotAPConfigured: Bool
    var hotspotAPActive: Bool? = nil
    var hotspotClientObserved: Bool? = nil
    let upstreamDevice: String
    let upstreamActive: Bool
    let sharingConfigured: Bool
    let sharingProcessRunning: Bool
    let forwardingEnabled: Bool
    let guardianObservedAt: String?
    let guardianGeneration: UInt64?
    let evidenceConflict: Bool
    let guardian: MacMiniGuardianStatus?

    static let guardianFreshnessWindow: TimeInterval = 45
    /// Guardian builds older than this still relaunch Apple sharing on a failed probe; the app keeps
    /// offering the update button until the Mini reports at least this version.
    static let requiredGuardianVersion = 2

    func guardianIsFresh(at date: Date, maximumAge: TimeInterval = guardianFreshnessWindow) -> Bool {
        guard let guardianObservedAt,
              let observed = ISO8601DateFormatter().date(from: guardianObservedAt) else {
            return false
        }
        let age = date.timeIntervalSince(observed)
        return age >= -5 && age <= maximumAge
    }

    var guardianNeedsUpdate: Bool {
        guard let guardian else { return false }
        return (guardian.guardianVersion ?? 1) < Self.requiredGuardianVersion
    }

    /// The Mini's sharing verdict has one owner: the Guardian, the only party with a clock (it is
    /// what tells a transient Apple rebuild from a stuck one).  The MacBook only vetoes it — when
    /// the helper's live facts contradict it, or when it is stale — and, without a fresh verdict,
    /// the raw facts may say what is wrong but never that the Mini is ready.
    func gatewayState(at now: Date) -> MacMiniGatewayState {
        if !sharingIntentEnabled { return .sharingManualPending }
        if !configured { return .managementLinkRecovering }
        if !upstreamActive { return .carrierDown }
        if !sharingConfigured { return .configurationDrift }
        if evidenceConflict { return .remoteEvidenceConflict }
        if let guardian, guardianIsFresh(at: now) {
            if guardianContradictsLiveFacts(guardian) { return .remoteEvidenceConflict }
            return guardian.state
        }
        if dhcpServerEnabled == false { return .sharingManualPending }
        if !sharingProcessRunning { return .sharingRecovering }
        if !forwardingEnabled { return .sharingForwardingUnavailable }
        if !bridgeUsesDHCP || serviceIPv4 == nil || gatewayIPv4 == nil { return .dhcpLeaseRecovering }
        return guardian == nil ? .unknown : .guardianStale
    }

    var gatewayState: MacMiniGatewayState { gatewayState(at: Date()) }

    /// A frozen status file (dead Guardian) keeps its old facts; the helper reads the live ones.
    /// Any disagreement means the verdict is not about the Mini as it is now.
    private func guardianContradictsLiveFacts(_ guardian: MacMiniGuardianStatus) -> Bool {
        if guardian.sharingRunning != sharingProcessRunning { return true }
        if guardian.forwardingEnabled != forwardingEnabled { return true }
        if guardian.carrierActive != upstreamActive { return true }
        if let intent = guardian.sharingIntentEnabled, intent != sharingIntentEnabled { return true }
        if let claimed = guardian.dhcpServerEnabled, let live = dhcpServerEnabled, claimed != live { return true }
        return false
    }
}

enum NetworkConfigurationMethod: String, Codable, Equatable {
    case dhcp
    case manual
}

struct NetworkServiceConfiguration: Codable, Equatable {
    let method: NetworkConfigurationMethod
    let ipAddress: String?
    let subnetMask: String?
    let router: String?
    let dnsServers: [String]
}
