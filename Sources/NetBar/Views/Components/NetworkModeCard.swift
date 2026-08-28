import AppKit
import SwiftUI

struct NetworkModeCard: View {
    @ObservedObject var controller: NetworkModeController
    @State private var showsWiFiCandidates = false
    @State private var showsAdvancedDiagnostics = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                hero

                evidenceGrid

                HStack(spacing: 0) {
                    modeButton(.macMiniGateway, icon: "desktopcomputer")
                    modeButton(.localWiFi, icon: "wifi")
                }
                .padding(3)
                .background(PopoverVisualStyle.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let policyMessage = controller.policyMessage, !policyMessage.isEmpty {
                    Text(policyMessage)
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                        .lineLimit(2)
                }

                criticalActions
                disclosureRows

                if let action = controller.lastClashAction {
                    HStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                        Text(action)
                            .lineLimit(1)
                        Spacer()
                        Button("查看日志") { openNetworkLog() }
                            .buttonStyle(.link)
                    }
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.warning)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(PopoverVisualStyle.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .help("切换的是 Wi-Fi 与雷雳网桥的物理出口优先级，不会关闭 Clash、aTrust、Tailscale 或其他 VPN。")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(statusColor)
                Text("Mac mini 链路")
                    .font(PopoverVisualStyle.Typography.section)
                Spacer()
                Text(currentOutletText)
                    .font(PopoverVisualStyle.Typography.bodyStrong)
                    .foregroundColor(statusColor)
            }

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(linkText)
                Spacer()
                Text(addressText)
                    .font(PopoverVisualStyle.Typography.data)
                    .truncationMode(.middle)
            }
            .font(PopoverVisualStyle.Typography.caption)
            .foregroundColor(.secondary)
        }
    }

    private var evidenceGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                evidenceTile(
                    title: "雷雳链路",
                    value: controller.snapshot?.linkState.displayName ?? "待检测",
                    detail: controller.snapshot?.bridgeIPv4 ?? "—",
                    healthy: controller.snapshot?.linkState == .connected
                )
                evidenceTile(
                    title: "Apple 共享出口",
                    value: controller.snapshot?.gatewayState.displayName ?? "待检测",
                    detail: controller.snapshot?.miniGateway ?? "—",
                    healthy: controller.snapshot?.gatewayState == .ready
                )
            }

            HStack(spacing: 12) {
                evidenceTile(
                    title: "端到端验证",
                    value: proofText,
                    detail: controller.failoverPhase.displayName,
                    healthy: controller.connectivityProofLevel == .activeVerified
                )
                evidenceTile(
                    title: "当前出口",
                    value: currentOutletText,
                    detail: controller.routePreference.displayName,
                    healthy: controller.connectivityProofLevel == .activeVerified
                )
            }
        }
    }

    private func evidenceTile(title: String, value: String, detail: String, healthy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(PopoverVisualStyle.Typography.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(healthy ? PopoverVisualStyle.healthy : PopoverVisualStyle.warning)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(PopoverVisualStyle.Typography.bodyStrong)
                    .lineLimit(1)
            }
            Text(detail)
                .font(PopoverVisualStyle.Typography.data)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentOutletText: String {
        controller.snapshot?.effectiveMode?.displayName ?? "待确认"
    }

    private var addressText: String {
        let local = controller.snapshot?.bridgeIPv4 ?? "—"
        let mini = controller.snapshot?.miniGateway ?? "—"
        return "本机 \(local) · Mini \(mini)"
    }

    private var proofText: String {
        switch controller.connectivityProofLevel {
        case .activeVerified: return "已验证"
        case .preflightEligible: return "预检通过"
        case .routeEligible: return "路由可用"
        case .degradedActive: return "受限可用"
        case .unavailable: return "不可用"
        }
    }

    @ViewBuilder
    private var criticalActions: some View {
        if controller.dnsPathFacts?.dependency == .miniDependent {
            actionButton(
                title: "恢复 Wi-Fi 自动 DNS",
                icon: "arrow.triangle.2.circlepath",
                disabled: controller.isRepairingDNS || controller.snapshot?.effectiveMode != .localWiFi
            ) {
                controller.repairWiFiDNS()
            }
        }

        if shouldOfferProvisioning {
            actionButton(
                title: "初始化/修复链路",
                icon: "wrench.and.screwdriver",
                disabled: controller.isSwitching || controller.isProvisioning
            ) {
                controller.initializeFixedLink()
            }
        } else if !controller.miniGuardianAvailable {
            actionButton(
                title: "安装/更新 Mini 自愈组件",
                icon: "arrow.triangle.2.circlepath",
                disabled: controller.isSwitching || controller.isProvisioning
            ) {
                controller.initializeFixedLink()
            }
        }

        if !controller.automationHelperAvailable {
            actionButton(title: "安装自动切换组件", icon: "lock.shield", disabled: false) {
                controller.installAutomationHelper()
            }
        }

        if let message = controller.errorMessage, !message.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: controller.requiresManualRecovery ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                Text(message).lineLimit(3)
                Spacer(minLength: 4)
                if controller.requiresManualRecovery {
                    Button("打开网络设置") { openNetworkSettings() }
                        .buttonStyle(.link)
                }
            }
            .font(PopoverVisualStyle.Typography.caption)
            .foregroundColor(controller.requiresManualRecovery ? PopoverVisualStyle.fault : PopoverVisualStyle.warning)
            .padding(10)
            .background(
                (controller.requiresManualRecovery ? PopoverVisualStyle.fault : PopoverVisualStyle.warning).opacity(0.07),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.bodyStrong)
                .foregroundColor(PopoverVisualStyle.healthy)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(PopoverVisualStyle.healthy.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(PopoverVisualStyle.healthy.opacity(0.16), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var disclosureRows: some View {
        VStack(spacing: 0) {
            Button {
                showsWiFiCandidates.toggle()
                if showsWiFiCandidates { controller.refreshWiFiCandidates() }
            } label: {
                disclosureLabel(
                    icon: "wifi",
                    title: "Wi-Fi 候选",
                    value: candidateCountText,
                    expanded: showsWiFiCandidates
                )
            }
            .buttonStyle(.plain)

            if showsWiFiCandidates {
                Divider().padding(.leading, 24)
                wifiCandidateList.padding(.vertical, 6)
            }

            Divider().padding(.leading, 24)

            Button {
                showsAdvancedDiagnostics.toggle()
            } label: {
                disclosureLabel(
                    icon: "stethoscope",
                    title: "高级诊断",
                    value: nil,
                    expanded: showsAdvancedDiagnostics
                )
            }
            .buttonStyle(.plain)

            if showsAdvancedDiagnostics {
                Divider().padding(.leading, 24)
                advancedDiagnostics.padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .popoverGroup()
    }

    private func disclosureLabel(icon: String, title: String, value: String?, expanded: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 16)
            Text(title).fontWeight(.medium)
            if let value {
                Text(value).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .foregroundColor(.secondary)
        }
        .font(PopoverVisualStyle.Typography.body)
        .foregroundColor(PopoverVisualStyle.primaryText)
        .frame(minHeight: 38)
        .contentShape(Rectangle())
    }

    private var advancedDiagnostics: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                evidenceItem(title: "固定管理链路", value: managementEvidenceText, healthy: managementEvidenceReady)
                evidenceItem(title: "DNS 独立性", value: controller.dnsPathFacts?.dependency.displayName ?? "待检测", healthy: dnsHealthy)
            }
            HStack(spacing: 10) {
                evidenceItem(title: "热点 AP", value: hotspotAPEvidenceText, healthy: controller.miniHelperStatus?.hotspotAPActive == true)
                evidenceItem(title: "客户端证据", value: hotspotClientEvidenceText, healthy: controller.miniHelperStatus?.hotspotClientObserved == true)
            }
            HStack {
                Text("代理不感知路径").foregroundColor(PopoverVisualStyle.secondaryText)
                Spacer()
                Text(proxyUnawareText)
                    .foregroundColor(controller.applicationPathFacts?.proxyUnawareHTTPSReady == true ? PopoverVisualStyle.healthy : PopoverVisualStyle.warning)
            }
            .font(PopoverVisualStyle.Typography.caption)
        }
    }

    private func modeButton(_ mode: NetworkRouteMode, icon: String) -> some View {
        let isSelected = mode == .macMiniGateway
            ? controller.routePreference == .miniPreferred
            : controller.routePreference == .localWiFi
        let isEnabled = canSwitch(to: mode)

        return PopoverSegmentedOption(
            title: mode == .macMiniGateway ? "Mac mini 优先" : "Wi-Fi 优先",
            icon: icon,
            isSelected: isSelected,
            isEnabled: isEnabled,
            accent: PopoverVisualStyle.healthy
        ) {
            controller.switchMode(to: mode)
        }
    }

    private func canSwitch(to mode: NetworkRouteMode) -> Bool {
        guard !controller.isSwitching, !controller.isProvisioning,
              let snapshot = controller.snapshot,
              snapshot.wifiServiceName != nil,
              snapshot.thunderboltServiceName != nil else {
            return false
        }
        return true
    }

    private var statusColor: Color {
        if controller.requiresManualRecovery {
            return PopoverVisualStyle.fault
        }
        guard let snapshot = controller.snapshot else {
            return PopoverVisualStyle.secondaryText
        }
        switch snapshot.linkState {
        case .unavailable, .disconnected:
            return PopoverVisualStyle.fault
        case .connected:
            return snapshot.gatewayState == .ready && snapshot.isConsistent
                ? PopoverVisualStyle.healthy
                : PopoverVisualStyle.warning
        case .addressNotProvisioned, .miniUnreachable:
            return PopoverVisualStyle.warning
        }
    }

    private var linkText: String {
        guard let snapshot = controller.snapshot else { return "正在检测雷雳链路" }
        if snapshot.linkState == .connected, snapshot.gatewayState != .ready {
            return "雷雳可用 · \(snapshot.gatewayState.displayName)"
        }
        return snapshot.linkState.displayName
    }

    private var managementEvidenceReady: Bool {
        controller.miniHelperStatus?.managementIPv4 == MacMiniLinkProfile.defaults.managementMiniAddress &&
            controller.snapshot?.linkState == .connected
    }

    private var managementEvidenceText: String {
        managementEvidenceReady ? "10.254.254.2 → 10.254.254.1" : "待验证"
    }

    private var hotspotAPEvidenceText: String {
        guard let status = controller.miniHelperStatus else { return "待检测" }
        if status.hotspotAPActive == true { return "AP 已建立" }
        return status.hotspotAPConfigured ? "已配置，尚未建立" : "未配置"
    }

    private var hotspotClientEvidenceText: String {
        if controller.miniHelperStatus?.hotspotClientObserved == true { return "客户端已观测" }
        return "热点已配置，客户端出口未验证"
    }

    private var candidateCountText: String {
        let count = controller.wifiCandidates.count
        return count == 0 ? "未发现" : "\(count) 个"
    }

    private var dnsHealthy: Bool {
        guard let facts = controller.dnsPathFacts else { return false }
        return facts.systemResolutionReady && facts.dependency != .miniDependent && facts.dependency != .unreachable
    }

    private var proxyUnawareText: String {
        controller.applicationPathFacts?.proxyUnawareHTTPSReady == true ? "可用" : "不可用"
    }

    private func evidenceItem(title: String, value: String, healthy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(PopoverVisualStyle.Typography.caption)
                .foregroundColor(PopoverVisualStyle.secondaryText)
            HStack(spacing: 4) {
                Circle()
                    .fill(healthy ? PopoverVisualStyle.healthy : PopoverVisualStyle.warning)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(PopoverVisualStyle.Typography.captionStrong)
                    .foregroundColor(PopoverVisualStyle.primaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var wifiCandidateList: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    .foregroundColor(PopoverVisualStyle.secondaryText)
            } else {
                ForEach(Array(controller.wifiCandidates.enumerated()), id: \.element.id) { index, candidate in
                    HStack(spacing: 6) {
                        Image(systemName: candidate.isCurrent ? "wifi.circle.fill" : "wifi")
                            .foregroundColor(candidate.state == .internetReady ? PopoverVisualStyle.healthy : PopoverVisualStyle.secondaryText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.displayName)
                                .font(.system(size: 10, weight: candidate.isCurrent ? .semibold : .regular))
                                .foregroundColor(PopoverVisualStyle.primaryText)
                                .lineLimit(1)
                            Text(candidateDetail(candidate))
                                .font(PopoverVisualStyle.Typography.caption)
                                .foregroundColor(PopoverVisualStyle.secondaryText)
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
                                    .foregroundColor(candidate.isPinned ? PopoverVisualStyle.warning : PopoverVisualStyle.secondaryText)
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
            }
        }
        .padding(10)
        .background(PopoverVisualStyle.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

}
