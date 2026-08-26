import Foundation

struct MacMiniLinkProfile: Codable, Equatable {
    let localAddress: String
    let gatewayAddress: String
    let subnetMask: String
    let miniUpstreamDevice: String
    let miniUpstreamAddress: String
    let miniUpstreamSubnetMask: String
    let miniUpstreamRouter: String
    let miniSSHUser: String
    let miniBonjourHost: String
    let probeTargets: [String]

    static let defaults = MacMiniLinkProfile(
        localAddress: "192.168.2.2",
        gatewayAddress: "192.168.2.1",
        subnetMask: "255.255.255.0",
        miniUpstreamDevice: "en0",
        miniUpstreamAddress: "10.32.143.206",
        miniUpstreamSubnetMask: "255.255.255.0",
        miniUpstreamRouter: "10.32.143.1",
        miniSSHUser: "zhangjian",
        miniBonjourHost: "zhangjiandemac-mini.local",
        probeTargets: ["1.1.1.1", "114.114.114.114"]
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

    var fixedHostKeyAlias: String { gatewayAddress }

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
    case unknown

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
            return "Mac mini 恢复等待中"
        case .routeFlapping:
            return "Mac mini 上游反复抖动"
        case .boundEgressUnavailable:
            return "Mac mini 出口探测失败"
        case .remoteStatusUnavailable:
            return "无法读取 Mac mini 状态"
        case .unknown:
            return "Mac mini 上游待检测"
        }
    }

    var isReady: Bool { self == .ready }
}

struct MacMiniGuardianStatus: Codable, Equatable {
    let state: MacMiniGatewayState
    let lastTransition: String?
    let lastCarrierChange: String?
    let lastAction: String?
    let lastError: String?
    let carrierActive: Bool
    let addressReady: Bool
    let routeReady: Bool
    let sharingRunning: Bool
    let sharingConfigured: Bool
    let upstreamReachable: Bool
    let nextRetryAt: String?
}

struct MacMiniHelperStatus: Codable, Equatable {
    let protocolVersion: Int
    let configured: Bool
    let serviceIPv4: String?
    let gatewayIPv4: String
    let upstreamDevice: String
    let upstreamActive: Bool
    let sharingConfigured: Bool
    let internetSharingRunning: Bool
    let guardian: MacMiniGuardianStatus?

    var gatewayState: MacMiniGatewayState {
        if !upstreamActive { return .carrierDown }
        if !sharingConfigured { return .configurationDrift }
        if !internetSharingRunning { return .sharingRecovering }
        if let guardian { return guardian.state }
        return .unknown
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
