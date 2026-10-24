import CryptoKit
import Combine
import Foundation

enum ClashOverlayMode: String, Codable, Equatable {
    case systemProxy
    case tunFull

    var displayName: String {
        switch self {
        case .systemProxy: return "系统代理"
        case .tunFull: return "TUN 全局"
        }
    }
}

enum ClashOverlayHealth: String, Equatable {
    case unavailable
    case configurationDrift
    case switching
    case ready
    case degraded

    var displayName: String {
        switch self {
        case .unavailable: return "Clash 控制面不可用"
        case .configurationDrift: return "共存基线需要修复"
        case .switching: return "正在切换"
        case .ready: return "数据面正常"
        case .degraded: return "代理数据面未收敛"
        }
    }
}

struct ClashOverlaySnapshot: Equatable {
    let mode: ClashOverlayMode?
    let runtimeTunEnabled: Bool?
    let persistentTunEnabled: Bool?
    let systemProxyEnabled: Bool
    let coexistenceBaselineReady: Bool
    let dataPlaneReady: Bool
    let health: ClashOverlayHealth
    let reason: String?
}
