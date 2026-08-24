import Foundation

enum DistributionFlavor: String {
    case appStoreLite
    case directFull

    static var current: DistributionFlavor {
        #if APP_STORE
        return .appStoreLite
        #else
        return .directFull
        #endif
    }

    var displayName: String {
        switch self {
        case .appStoreLite:
            return "App Store Lite"
        case .directFull:
            return "Direct Full"
        }
    }

    var supportsProcessTraffic: Bool {
        switch self {
        case .appStoreLite:
            return false
        case .directFull:
            return true
        }
    }

    var supportsAdvancedProxyDetection: Bool {
        switch self {
        case .appStoreLite:
            return false
        case .directFull:
            return true
        }
    }

    var usesLaunchAgentStartup: Bool {
        switch self {
        case .appStoreLite:
            return false
        case .directFull:
            return true
        }
    }

    var supportsNetworkModeSwitch: Bool {
        switch self {
        case .appStoreLite:
            return false
        case .directFull:
            return true
        }
    }
}
