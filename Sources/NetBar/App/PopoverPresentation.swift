import Foundation

enum PopoverSection: String, CaseIterable, Equatable {
    case outlet
    case clash
    case applications
    case monitoring

    var title: String {
        switch self {
        case .outlet: return "出口"
        case .clash: return "Clash"
        case .applications: return "应用"
        case .monitoring: return "监控"
        }
    }

    var systemImage: String {
        switch self {
        case .outlet: return "desktopcomputer"
        case .clash: return "shield.lefthalf.filled"
        case .applications: return "square.grid.2x2"
        case .monitoring: return "chart.bar.fill"
        }
    }

    static func available(for flavor: DistributionFlavor) -> [PopoverSection] {
        switch flavor {
        case .directFull:
            return allCases
        case .appStoreLite:
            return [.monitoring]
        }
    }

    static func defaultSection(for flavor: DistributionFlavor) -> PopoverSection {
        flavor == .directFull ? .outlet : .monitoring
    }

    static func resolve(storedValue: String?, flavor: DistributionFlavor) -> PopoverSection {
        let available = available(for: flavor)
        guard let storedValue,
              let stored = PopoverSection(rawValue: storedValue),
              available.contains(stored) else {
            return defaultSection(for: flavor)
        }
        return stored
    }
}

enum PopoverConnectivityState: Equatable {
    case online
    case limited
    case recovering
    case offline

    var displayName: String {
        switch self {
        case .online: return "在线"
        case .limited: return "受限在线"
        case .recovering: return "恢复中"
        case .offline: return "离线"
        }
    }
}

enum PopoverStatusTone: Equatable {
    case positive
    case caution
    case negative
    case neutral
}

struct PopoverStatusPresentation: Equatable {
    let connectivity: PopoverConnectivityState
    let tone: PopoverStatusTone
    let outletText: String
    let clashText: String
    let dnsText: String
    let primaryReason: String?
    let outletNeedsAttention: Bool
    let clashNeedsAttention: Bool
    let monitoringNeedsAttention: Bool

    init(
        proofLevel: ConnectivityProofLevel,
        effectiveMode: NetworkRouteMode?,
        overlay: ClashOverlaySnapshot,
        dnsFacts: DNSPathFacts?,
        primaryReason: String?
    ) {
        let dnsReady = dnsFacts?.systemResolutionReady == true &&
            dnsFacts?.dependency != .miniDependent &&
            dnsFacts?.dependency != .unreachable
        let overlayReady = overlay.health == .ready && overlay.dataPlaneReady

        switch proofLevel {
        case .activeVerified where overlayReady && dnsReady:
            connectivity = .online
            tone = .positive
        case .activeVerified, .degradedActive:
            connectivity = .limited
            tone = .caution
        case .routeEligible, .preflightEligible:
            connectivity = .recovering
            tone = .caution
        case .unavailable:
            connectivity = .offline
            tone = .negative
        }

        switch effectiveMode {
        case .macMiniGateway: outletText = "Mac mini"
        case .localWiFi: outletText = "Wi-Fi"
        case nil: outletText = "待验证"
        }

        switch overlay.mode {
        case .tunFull: clashText = "TUN"
        case .systemProxy: clashText = "系统代理"
        case nil: clashText = "待检测"
        }

        switch dnsFacts?.dependency {
        case .independent: dnsText = "正常"
        case .overlayOnly: dnsText = "TUN 接管"
        case .miniDependent: dnsText = "依赖 Mini"
        case .unreachable: dnsText = "不可用"
        case .unknown, nil: dnsText = "待检测"
        }

        self.primaryReason = primaryReason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        outletNeedsAttention = proofLevel != .activeVerified
        clashNeedsAttention = overlay.health != .ready
        monitoringNeedsAttention = !dnsReady
    }

    func needsAttention(_ section: PopoverSection) -> Bool {
        switch section {
        case .outlet: return outletNeedsAttention
        case .clash: return clashNeedsAttention
        case .applications: return false
        case .monitoring: return monitoringNeedsAttention
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
