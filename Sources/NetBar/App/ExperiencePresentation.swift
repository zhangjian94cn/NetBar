import Foundation

enum ProbeDisplayState: String, Equatable {
    case notChecked, running, passed, failed, blocked, stale
    var title: String {
        switch self {
        case .notChecked: return "尚未检测"
        case .running: return "正在检测"
        case .passed: return "DNS / HTTPS 通过"
        case .failed: return "检测未通过"
        case .blocked: return "检测条件不足"
        case .stale: return "结果已过期"
        }
    }
    var factState: PopoverFactState {
        switch self {
        case .passed: return .ok
        case .failed: return .fault
        case .blocked: return .warning
        default: return .unknown
        }
    }
    static func resolve(snapshot: ClashNetworkModeSnapshot, probe: ClashNetworkProbe?,
                        previous: ClashNetworkProbe?, running: Bool, now: Date = Date()) -> Self {
        if running { return .running }
        if let probe, probe.isFresh(for: snapshot, now: now) {
            return probe.blocked ? .blocked : (probe.passed ? .passed : .failed)
        }
        if probe != nil || previous != nil { return .stale }
        if snapshot.mode == .unifiedEgress, snapshot.reason?.hasPrefix("统一保障条件未满足") == true { return .blocked }
        return .notChecked
    }
}

struct ExperiencePresentation {
    let headline: String
    let state: PopoverFactState
    let physicalPath: String
    let strategy: String
    let probeState: ProbeDisplayState

    init(proof: ConnectivityProofLevel, mode: NetworkRouteMode?, hasPhysicalSample: Bool,
         physicalError: String?, clash: ClashNetworkModeSnapshot, probe: ClashNetworkProbe?,
         previousProbe: ClashNetworkProbe?, probing: Bool, now: Date = Date()) {
        switch proof {
        case .activeVerified: headline = "网络可用"; state = .ok
        case .degradedActive: headline = "网络受限"; state = .warning
        case .routeEligible, .preflightEligible: headline = "正在确认网络"; state = .unknown
        case .unavailable:
            let failed = physicalError?.isEmpty == false
            headline = failed ? "网络需要检查" : (hasPhysicalSample ? "出口待验证" : "正在读取网络")
            state = failed ? .warning : .unknown
        }
        switch mode {
        case .macMiniGateway: physicalPath = "雷雳 → Mac mini"
        case .localWiFi: physicalPath = "本机 → Wi-Fi"
        case nil: physicalPath = "出口待确认"
        }
        if let runtime = clash.runtime, !runtime.tunEnabled && !runtime.systemProxyEnabled {
            strategy = "Clash 接管已关闭"
        } else {
            switch clash.mode {
            case .companyCoexistence: strategy = "公司共存 · 按域名分流"
            case .unifiedEgress: strategy = "统一出口 · 候选"
            case .originalNetwork: strategy = "原网络"
            case nil: strategy = clash.runtime == nil ? "Clash 状态待读取" : "其他 Clash 配置"
            }
        }
        probeState = ProbeDisplayState.resolve(snapshot: clash, probe: probe, previous: previousProbe, running: probing, now: now)

    }
}

/// Set membership prevents one surface closing from hiding another consumer.
struct VisibleDataConsumers {
    private(set) var consumers: Set<String> = []
    mutating func set(_ id: String, visible: Bool) {
        if visible { consumers.insert(id) } else { consumers.remove(id) }
    }
    var needsDetails: Bool { !consumers.isEmpty }
}
