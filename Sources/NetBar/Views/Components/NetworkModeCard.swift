import AppKit
import SwiftUI

struct NetworkModeCard: View {
    @ObservedObject var controller: NetworkModeController
    @State private var showsWiFiCandidates = false
    @State private var showsAdvancedDiagnostics = false

    private var presentation: NetworkOutletPresentation {
        NetworkOutletPresentation(
            snapshot: controller.snapshot,
            helperStatus: controller.miniHelperStatus,
            proofLevel: controller.connectivityProofLevel,
            failoverPhase: controller.failoverPhase,
            routePreference: controller.routePreference,
            requiresManualRecovery: controller.requiresManualRecovery,
            dnsFacts: controller.dnsPathFacts,
            applicationFacts: controller.applicationPathFacts
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: PopoverVisualStyle.blockSpacing) {
                hero
                evidenceGrid
                modeSelector

                if let policyMessage = controller.policyMessage, !policyMessage.isEmpty {
                    Text(policyMessage)
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                        .lineLimit(2)
                }

                criticalActions
                disclosureRows

                if let action = controller.lastClashAction {
                    PopoverBanner(
                        message: action,
                        icon: "point.3.connected.trianglepath.dotted",
                        lineLimit: 1
                    ) {
                        Button("查看日志") { openNetworkLog() }
                            .buttonStyle(.link)
                            .font(PopoverVisualStyle.Typography.caption)
                    }
                }
            }
            .padding(.horizontal, PopoverVisualStyle.contentInset)
            .padding(.vertical, PopoverVisualStyle.Spacing.sm)
        }
        .help("切换的是 Wi-Fi 与雷雳网桥的物理出口优先级，不会关闭 Clash、aTrust、Tailscale 或其他 VPN。")
    }

    private var hero: some View {
        let facts = presentation
        return VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.xs + 2) {
            HStack(spacing: PopoverVisualStyle.Spacing.sm) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(PopoverVisualStyle.secondaryText)
                Text("Mac mini 链路")
                    .font(PopoverVisualStyle.Typography.section)
                Spacer()
                PopoverStatusDot(state: facts.heroState)
                Text(facts.outletText)
                    .font(PopoverVisualStyle.Typography.bodyStrong)
                    .foregroundColor(PopoverVisualStyle.primaryText)
            }

            // The link state itself is the first evidence tile below, so the
            // hero only adds what the grid does not carry: the addresses.
            if !facts.addressText.isEmpty {
                Text(facts.addressText)
                    .font(PopoverVisualStyle.Typography.data)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
                    .truncationMode(.middle)
            } else {
                Text(facts.linkText)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
            }
        }
    }

    private var evidenceGrid: some View {
        let facts = presentation
        return VStack(spacing: PopoverVisualStyle.blockSpacing) {
            HStack(spacing: PopoverVisualStyle.Spacing.sm + 2) {
                PopoverFactTile(
                    title: "雷雳链路",
                    value: facts.linkValue,
                    detail: facts.linkDetail,
                    state: facts.linkStateDot
                )
                PopoverFactTile(
                    title: "Apple 共享出口",
                    value: facts.sharingValue,
                    detail: facts.sharingDetail,
                    state: facts.sharingStateDot
                )
            }
            HStack(spacing: PopoverVisualStyle.Spacing.sm + 2) {
                PopoverFactTile(
                    title: "端到端验证",
                    value: facts.proofValue,
                    detail: facts.proofDetail,
                    state: facts.proofStateDot
                )
                PopoverFactTile(
                    title: "当前出口",
                    value: facts.outletText,
                    detail: facts.preferenceDetail,
                    state: facts.outletStateDot
                )
            }
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            modeButton(.macMiniGateway, icon: "desktopcomputer")
            modeButton(.localWiFi, icon: "wifi")
        }
        .popoverSegmentedTrack()
    }

    private func modeButton(_ mode: NetworkRouteMode, icon: String) -> some View {
        let isSelected = mode == .macMiniGateway
            ? controller.routePreference == .miniPreferred
            : controller.routePreference == .localWiFi

        return PopoverSegmentedOption(
            title: mode == .macMiniGateway ? "Mac mini 优先" : "Wi-Fi 优先",
            icon: icon,
            isSelected: isSelected,
            isEnabled: canSwitch()
        ) {
            controller.switchMode(to: mode)
        }
    }

    @ViewBuilder
    private var criticalActions: some View {
        if controller.dnsPathFacts?.hasLegacyMiniResolver == true {
            PopoverActionButton(
                title: "清理旧 Mini DNS",
                icon: "trash.slash",
                isDisabled: controller.isRepairingDNS || controller.snapshot?.effectiveMode != .localWiFi
            ) {
                controller.removeLegacyMiniDNS()
            }
        }

        if controller.dnsPathFacts?.dependency == .miniDependent {
            PopoverActionButton(
                title: "恢复 Wi-Fi 自动 DNS",
                icon: "arrow.triangle.2.circlepath",
                isDisabled: controller.isRepairingDNS || controller.snapshot?.effectiveMode != .localWiFi
            ) {
                controller.repairWiFiDNS()
            }
        }

        if shouldOfferProvisioning {
            PopoverActionButton(
                title: "初始化/修复链路",
                icon: "wrench.and.screwdriver",
                isDisabled: controller.isSwitching || controller.isProvisioning
            ) {
                controller.initializeFixedLink()
            }
        } else if !controller.miniGuardianAvailable {
            PopoverActionButton(
                title: "安装/更新 Mini 自愈组件",
                icon: "arrow.triangle.2.circlepath",
                isDisabled: controller.isSwitching || controller.isProvisioning
            ) {
                controller.initializeFixedLink()
            }
        }

        if !controller.automationHelperAvailable {
            PopoverActionButton(title: "安装自动切换组件", icon: "lock.shield") {
                controller.installAutomationHelper()
            }
        }

        if let message = controller.errorMessage, !message.isEmpty {
            PopoverBanner(
                message: message,
                tone: controller.requiresManualRecovery ? .negative : .caution
            ) {
                if controller.requiresManualRecovery {
                    Button("打开网络设置") { openNetworkSettings() }
                        .buttonStyle(.link)
                        .font(PopoverVisualStyle.Typography.caption)
                }
            }
        }
    }

    private var disclosureRows: some View {
        VStack(spacing: 0) {
            PopoverDisclosure(
                icon: "wifi",
                title: "Wi-Fi 候选",
                value: candidateCountText,
                isExpanded: $showsWiFiCandidates,
                onExpand: { controller.refreshWiFiCandidates() }
            ) {
                wifiCandidateList
            }

            Divider()

            PopoverDisclosure(
                icon: "stethoscope",
                title: "高级诊断",
                isExpanded: $showsAdvancedDiagnostics
            ) {
                advancedDiagnostics
            }
        }
        .padding(.horizontal, PopoverVisualStyle.cardPadding)
        .popoverSurface()
    }

    private var advancedDiagnostics: some View {
        let facts = presentation
        return VStack(spacing: 0) {
            Divider()
            PopoverFactRow(
                title: "固定管理链路",
                value: facts.managementValue,
                state: facts.managementState,
                compact: true
            )
            PopoverFactRow(title: "DNS 独立性", value: facts.dnsValue, state: facts.dnsState, compact: true)
            PopoverFactRow(title: "热点 AP", value: facts.hotspotAPValue, state: facts.hotspotAPState, compact: true)
            PopoverFactRow(
                title: "客户端证据",
                value: facts.hotspotClientValue,
                state: facts.hotspotClientState,
                compact: true
            )
            PopoverFactRow(
                title: "代理不感知路径",
                value: facts.proxyUnawareValue,
                state: facts.proxyUnawareState,
                compact: true
            )
        }
    }

    @ViewBuilder
    private var wifiCandidateList: some View {
        VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.sm) {
            Divider()
            HStack {
                Text(candidateAccessText)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
                Spacer()
                if controller.wifiLocationAccess == .notDetermined {
                    Button("允许扫描") { controller.requestWiFiLocationAccess() }
                        .buttonStyle(.link)
                        .font(PopoverVisualStyle.Typography.caption)
                }
                Button("刷新") { controller.refreshWiFiCandidates() }
                    .buttonStyle(.link)
                    .font(PopoverVisualStyle.Typography.caption)
            }

            if controller.wifiCandidates.isEmpty {
                Text("当前没有可用连接。允许定位后可发现附近已保存的 Wi-Fi。")
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
            } else {
                ForEach(Array(controller.wifiCandidates.enumerated()), id: \.element.id) { index, candidate in
                    candidateRow(candidate, index: index)
                }
            }
        }
    }

    private func candidateRow(_ candidate: NetworkAccessCandidate, index: Int) -> some View {
        HStack(spacing: PopoverVisualStyle.Spacing.sm) {
            Image(systemName: candidate.isCurrent ? "wifi.circle.fill" : "wifi")
                .foregroundColor(candidate.state == .internetReady
                                 ? PopoverVisualStyle.healthy
                                 : PopoverVisualStyle.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.displayName)
                    .font(.system(size: 11, weight: candidate.isCurrent ? .semibold : .regular))
                    .foregroundColor(PopoverVisualStyle.primaryText)
                    .lineLimit(1)
                Text(candidateDetail(candidate))
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
            }
            Spacer()
            if candidate.id != WiFiCandidateSelector.anonymousCurrentID, candidate.isPinned {
                Button { controller.moveWiFiCandidate(candidate.displayName, offset: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                Button { controller.moveWiFiCandidate(candidate.displayName, offset: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
            }
            if candidate.id != WiFiCandidateSelector.anonymousCurrentID {
                Button {
                    controller.setWiFiCandidate(candidate.displayName, pinned: !candidate.isPinned)
                } label: {
                    Image(systemName: candidate.isPinned ? "star.fill" : "star")
                        .foregroundColor(candidate.isPinned
                                         ? PopoverVisualStyle.accent
                                         : PopoverVisualStyle.tertiaryText)
                }
                .buttonStyle(.plain)
                .help(candidate.isPinned ? "从自动候选中移除" : "加入自动候选并置顶")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(PopoverVisualStyle.healthy)
                    .help("当前连接可直接用于故障回退")
            }
        }
        .padding(.vertical, 2)
    }

    private func canSwitch() -> Bool {
        guard !controller.isSwitching, !controller.isProvisioning,
              let snapshot = controller.snapshot,
              snapshot.wifiServiceName != nil,
              snapshot.thunderboltServiceName != nil else {
            return false
        }
        return true
    }

    private var candidateCountText: String {
        let count = controller.wifiCandidates.count
        return count == 0 ? "未发现" : "\(count) 个"
    }

    private func candidateDetail(_ candidate: NetworkAccessCandidate) -> String {
        let signal = candidate.signalStrength.map { " · \($0) dBm" } ?? ""
        let current = candidate.isCurrent ? "当前连接 · " : ""
        return "\(current)\(candidate.state.displayName)\(signal)"
    }

    private var candidateAccessText: String {
        if controller.wifiCandidates.contains(where: { $0.id == WiFiCandidateSelector.anonymousCurrentID }) {
            return "当前连接可用；允许定位后可扫描其他 Wi-Fi"
        }
        return controller.wifiLocationAccess.displayName
    }

    private var shouldOfferProvisioning: Bool {
        guard let snapshot = controller.snapshot else { return false }
        switch snapshot.linkState {
        case .addressNotProvisioned, .miniUnreachable:
            return true
        case .connected, .disconnected, .unavailable:
            return false
        }
    }

    private func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func openNetworkLog() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NetBar", isDirectory: true)
        let log = directory.appendingPathComponent("network-events.jsonl")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}
