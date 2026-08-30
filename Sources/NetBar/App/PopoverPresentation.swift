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
        primaryReason: String?,
        outletFault: Bool = false
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

        let baseDNSText: String
        switch dnsFacts?.dependency {
        case .independent: baseDNSText = "正常"
        case .overlayOnly: baseDNSText = "TUN 接管"
        case .miniDependent: baseDNSText = "依赖 Mini"
        case .unreachable: baseDNSText = "不可用"
        case .unknown, nil: baseDNSText = "待检测"
        }
        dnsText = dnsFacts?.hasLegacyMiniResolver == true && dnsFacts?.effectiveDNSReady == true
            ? "正常 · 含旧 Mini DNS"
            : baseDNSText

        self.primaryReason = primaryReason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // Tab badges mark work the user can actually do something about.
        // Treating "not verified yet" or "currently switching" as an alert put a
        // dot on three of four tabs at all times, which made the badge carry no
        // information at all.
        outletNeedsAttention = outletFault || proofLevel == .unavailable
        switch overlay.health {
        case .unavailable, .configurationDrift, .degraded:
            clashNeedsAttention = true
        case .ready, .switching:
            clashNeedsAttention = false
        }
        if dnsFacts?.hasLegacyMiniResolver == true {
            monitoringNeedsAttention = true
        } else {
            switch dnsFacts?.dependency {
            case .miniDependent, .unreachable:
                monitoringNeedsAttention = true
            case .independent, .overlayOnly, .unknown, nil:
                monitoringNeedsAttention = false
            }
        }
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

/// Display logic for the outlet page.
///
/// The information-architecture ADR names the presentation layer the single
/// owner of popover display logic; the outlet page had grown its own copy of
/// that logic inside the view, where it could not be unit tested.
struct NetworkOutletPresentation: Equatable {
    let outletText: String
    let heroState: PopoverFactState
    let linkText: String
    let addressText: String

    let linkValue: String
    let linkDetail: String?
    let linkStateDot: PopoverFactState

    let sharingValue: String
    let sharingDetail: String?
    let sharingStateDot: PopoverFactState

    let proofValue: String
    let proofDetail: String
    let proofStateDot: PopoverFactState

    let preferenceDetail: String
    let outletStateDot: PopoverFactState

    let managementValue: String
    let managementState: PopoverFactState
    let dnsValue: String
    let dnsState: PopoverFactState
    let hotspotAPValue: String
    let hotspotAPState: PopoverFactState
    let hotspotClientValue: String
    let hotspotClientState: PopoverFactState
    let proxyUnawareValue: String
    let proxyUnawareState: PopoverFactState

    init(
        snapshot: NetworkModeSnapshot?,
        helperStatus: MacMiniHelperStatus?,
        proofLevel: ConnectivityProofLevel,
        failoverPhase: NetworkFailoverPhase,
        routePreference: NetworkRoutePreference,
        requiresManualRecovery: Bool,
        dnsFacts: DNSPathFacts?,
        applicationFacts: ApplicationPathFacts?
    ) {
        outletText = snapshot?.effectiveMode?.displayName ?? "待确认"

        if requiresManualRecovery {
            heroState = .fault
        } else if let snapshot {
            switch snapshot.linkState {
            case .unavailable, .disconnected:
                heroState = .fault
            case .connected:
                heroState = snapshot.gatewayState == .ready && snapshot.isConsistent ? .ok : .warning
            case .addressNotProvisioned, .miniUnreachable:
                heroState = .warning
            }
        } else {
            heroState = .unknown
        }

        if let snapshot {
            if snapshot.linkState == .connected, snapshot.gatewayState != .ready {
                linkText = "雷雳可用 · \(snapshot.gatewayState.displayName)"
            } else {
                linkText = snapshot.linkState.displayName
            }
        } else {
            linkText = "正在检测雷雳链路"
        }

        addressText = Self.addressText(local: snapshot?.bridgeIPv4, mini: snapshot?.miniGateway)

        linkValue = snapshot?.linkState.displayName ?? "待检测"
        linkDetail = snapshot?.bridgeIPv4
        linkStateDot = snapshot.map { $0.linkState == .connected ? .ok : .warning } ?? .unknown

        sharingValue = snapshot?.gatewayState.displayName ?? "待检测"
        sharingDetail = snapshot?.miniGateway
        sharingStateDot = snapshot.map { $0.gatewayState == .ready ? .ok : .warning } ?? .unknown

        switch proofLevel {
        case .activeVerified: proofValue = "已验证"
        case .preflightEligible: proofValue = "预检通过"
        case .routeEligible: proofValue = "路由可用"
        case .degradedActive: proofValue = "受限可用"
        case .unavailable: proofValue = "不可用"
        }
        proofDetail = failoverPhase.displayName
        switch proofLevel {
        case .activeVerified: proofStateDot = .ok
        case .preflightEligible, .routeEligible, .degradedActive: proofStateDot = .warning
        case .unavailable: proofStateDot = snapshot == nil ? .unknown : .warning
        }

        preferenceDetail = routePreference.displayName
        // The active outlet is a fact, not a proof: being on Wi-Fi is a normal
        // working state and must not inherit the end-to-end verification dot.
        outletStateDot = snapshot?.effectiveMode == nil ? .unknown : .ok

        let managementReady = helperStatus?.managementIPv4 == MacMiniLinkProfile.defaults.managementMiniAddress &&
            snapshot?.linkState == .connected
        managementValue = managementReady
            ? "\(MacMiniLinkProfile.defaults.managementLocalAddress) → \(MacMiniLinkProfile.defaults.managementMiniAddress)"
            : "待验证"
        managementState = helperStatus == nil ? .unknown : (managementReady ? .ok : .warning)

        if dnsFacts?.hasLegacyMiniResolver == true, dnsFacts?.effectiveDNSReady == true {
            dnsValue = "DNS 可用 · 含旧 Mini 地址"
        } else {
            dnsValue = dnsFacts?.dependency.displayName ?? "待检测"
        }
        if let dnsFacts {
            let healthy = dnsFacts.systemResolutionReady &&
                dnsFacts.dependency != .miniDependent &&
                dnsFacts.dependency != .unreachable
            dnsState = healthy ? .ok : .warning
        } else {
            dnsState = .unknown
        }

        if let helperStatus {
            if helperStatus.hotspotAPActive == true {
                hotspotAPValue = "AP 已建立"
                hotspotAPState = .ok
            } else {
                hotspotAPValue = helperStatus.hotspotAPConfigured ? "已配置，尚未建立" : "未配置"
                hotspotAPState = helperStatus.hotspotAPConfigured ? .warning : .unknown
            }
            if helperStatus.hotspotClientObserved == true {
                hotspotClientValue = "客户端已观测"
                hotspotClientState = .ok
            } else {
                hotspotClientValue = "客户端出口未验证"
                hotspotClientState = .unknown
            }
        } else {
            hotspotAPValue = "待检测"
            hotspotAPState = .unknown
            hotspotClientValue = "待检测"
            hotspotClientState = .unknown
        }

        proxyUnawareState = PopoverFactState(ready: applicationFacts?.proxyUnawareHTTPSReady)
        switch proxyUnawareState {
        case .ok: proxyUnawareValue = "可用"
        case .warning, .fault: proxyUnawareValue = "不可用"
        case .unknown: proxyUnawareValue = "待检测"
        }
    }

    /// Only renders the halves that are actually known, so a panel that has not
    /// sampled yet does not show "本机 — · Mini —".
    static func addressText(local: String?, mini: String?) -> String {
        var parts: [String] = []
        if let local, !local.isEmpty { parts.append("本机 \(local)") }
        if let mini, !mini.isEmpty { parts.append("Mini \(mini)") }
        return parts.joined(separator: " · ")
    }
}
