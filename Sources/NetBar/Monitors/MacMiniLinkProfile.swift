import Foundation

struct MacMiniLinkProfile: Codable, Equatable {
    let localAddress: String
    let gatewayAddress: String
    let subnetMask: String
    let miniUpstreamDevice: String
    let miniSSHUser: String
    let miniBonjourHost: String
    let probeTargets: [String]

    static let defaults = MacMiniLinkProfile(
        localAddress: "192.168.2.2",
        gatewayAddress: "192.168.2.1",
        subnetMask: "255.255.255.0",
        miniUpstreamDevice: "en0",
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

enum MacMiniGatewayState: Equatable {
    case ready
    case upstreamUnavailable
    case unknown

    var displayName: String {
        switch self {
        case .ready:
            return "Mac mini 上游正常"
        case .upstreamUnavailable:
            return "Mac mini 上游不可用"
        case .unknown:
            return "Mac mini 上游待检测"
        }
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
