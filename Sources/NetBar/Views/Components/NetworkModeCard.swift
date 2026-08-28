import AppKit
import SwiftUI

struct NetworkModeCard: View {
    @ObservedObject var controller: NetworkModeController
    @State private var showsWiFiCandidates = false
    @State private var showsAdvancedDiagnostics = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 11) {
                hero

                HStack(spacing: 0) {
                    modeButton(.macMiniGateway, icon: "desktopcomputer")
                    modeButton(.localWiFi, icon: "wifi")
                }
                .padding(2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                if let policyMessage = controller.policyMessage, !policyMessage.isEmpty {
                    Text(policyMessage)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                criticalActions
                healthSteps
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
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .help("切换的是 Wi-Fi 与雷雳网桥的物理出口优先级，不会关闭 Clash、aTrust、Tailscale 或其他 VPN。")
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(heroTitle)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(heroSubtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if controller.isSwitching || controller.isProvisioning {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var heroTitle: String {
        switch controller.snapshot?.effectiveMode {
        case .macMiniGateway: return "当前经 Mac mini 联网"
        case .localWiFi: return "当前经 Wi-Fi 联网"
        case nil: return "正在确认网络出口"
        }
    }

    private var heroSubtitle: String {
        let dns = controller.dnsPathFacts?.dependency.displayName ?? "DNS 待检测"
        return "\(linkText) · \(dns)"
    }

    private var healthSteps: some View {
        VStack(spacing: 0) {
            healthStep(
                title: "雷雳链路\(controller.snapshot?.linkState == .connected ? "正常" : "待恢复")",
                detail: addressText,
                healthy: controller.snapshot?.linkState == .connected,
                icon: "bolt.horizontal.fill"
            )
            Divider().padding(.leading, 34)
            healthStep(
                title: "Apple 共享出口\(controller.snapshot?.gatewayState == .ready ? "正常" : "待恢复")",
                detail: sharingOutletEvidenceText,
                healthy: controller.snapshot?.gatewayState == .ready,
                icon: "arrow.triangle.branch"
            )
            Divider().padding(.leading, 34)
            healthStep(
                title: controller.connectivityProofLevel == .activeVerified ? "端到端验证通过" : "端到端验证待完成",
                detail: controller.connectivityProofLevel == .activeVerified ? "系统与代理数据面均已验证" : controller.failoverPhase.displayName,
                healthy: controller.connectivityProofLevel == .activeVerified,
                icon: "checkmark.shield.fill"
            )
        }
    }

    private func healthStep(title: String, detail: String, healthy: Bool, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle()
                    .fill((healthy ? Color.green : Color.orange).opacity(0.14))
                    .frame(width: 25, height: 25)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(healthy ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 7)
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
            .font(.system(size: 9))
            .foregroundColor(controller.requiresManualRecovery ? .red : .orange)
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
                .font(.system(size: 9, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
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
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        .font(.system(size: 10))
        .frame(minHeight: 34)
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
                Text("代理不感知路径").foregroundColor(.secondary)
                Spacer()
                Text(proxyUnawareText)
                    .foregroundColor(controller.applicationPathFacts?.proxyUnawareHTTPSReady == true ? .green : .orange)
            }
            .font(.system(size: 9))
        }
    }

    private func modeButton(_ mode: NetworkRouteMode, icon: String) -> some View {
        let isSelected = mode == .macMiniGateway
            ? controller.routePreference == .miniPreferred
            : controller.routePreference == .localWiFi
        let isEnabled = canSwitch(to: mode)
        let selectedColor: Color = mode == .macMiniGateway ? .green : .blue

        return Button {
            controller.switchMode(to: mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode == .macMiniGateway ? "Mac mini 优先" : "Wi-Fi 优先")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 25)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? selectedColor.opacity(0.9) : Color.primary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? selectedColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
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
            return .red
        }
        guard let snapshot = controller.snapshot else {
            return .secondary
        }
        switch snapshot.linkState {
        case .unavailable, .disconnected:
            return .red
        case .connected:
            return snapshot.gatewayState == .ready && snapshot.isConsistent ? .green : .orange
        case .addressNotProvisioned, .miniUnreachable:
            return .orange
        }
    }

    private var modeText: String {
        guard let snapshot = controller.snapshot else { return "正在检测" }
        if controller.requiresManualRecovery {
            return "需要手动恢复"
        }
        if snapshot.linkState == .addressNotProvisioned {
            return "需要初始化"
        }
        if snapshot.gatewayState != .ready, snapshot.gatewayState != .unknown {
            return snapshot.gatewayState.displayName
        }
        if snapshot.isConsistent, let mode = snapshot.effectiveMode {
            return mode.displayName
        }
        return "配置不一致"
    }

    private var linkText: String {
        guard let snapshot = controller.snapshot else { return "正在检测雷雳链路" }
        if snapshot.linkState == .connected, snapshot.gatewayState != .ready {
            return "雷雳可用 · \(snapshot.gatewayState.displayName)"
        }
        return snapshot.linkState.displayName
    }

    private var currentOutletText: String {
        if let activeCandidate = controller.activeCandidateName,
           controller.snapshot?.effectiveMode == .localWiFi {
            return "Wi-Fi · \(activeCandidate)"
        }
        return controller.snapshot?.effectiveMode?.displayName ?? "待检测"
    }

    private var addressText: String {
        guard let snapshot = controller.snapshot else { return "—" }
        let local = snapshot.bridgeIPv4 ?? "—"
        let mini = snapshot.miniGateway ?? "—"
        return "本机 \(local) · Mini \(mini)"
    }

    private var managementEvidenceReady: Bool {
        controller.miniHelperStatus?.managementIPv4 == MacMiniLinkProfile.defaults.managementMiniAddress &&
            controller.snapshot?.linkState == .connected
    }

    private var managementEvidenceText: String {
        managementEvidenceReady ? "10.254.254.2 → 10.254.254.1" : "待验证"
    }

    private var sharingOutletEvidenceText: String {
        guard let snapshot = controller.snapshot,
              let address = snapshot.bridgeIPv4,
              let gateway = snapshot.miniGateway else { return "等待 Apple DHCP" }
        return "\(address) → \(gateway)"
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
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(healthy ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text(value)
                    .font(.system(size: 9, weight: .medium))
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
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                if controller.wifiLocationAccess == .notDetermined {
                    Button("允许扫描") { controller.requestWiFiLocationAccess() }
                        .buttonStyle(.link)
                        .font(.system(size: 9))
                }
                Button("刷新") { controller.refreshWiFiCandidates() }
                    .buttonStyle(.link)
                    .font(.system(size: 9))
            }

            if controller.wifiCandidates.isEmpty {
                Text("当前没有可用连接。允许定位后可发现附近已保存的 Wi-Fi。")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(controller.wifiCandidates.enumerated()), id: \.element.id) { index, candidate in
                    HStack(spacing: 6) {
                        Image(systemName: candidate.isCurrent ? "wifi.circle.fill" : "wifi")
                            .foregroundColor(candidate.state == .internetReady ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.displayName)
                                .font(.system(size: 9, weight: candidate.isCurrent ? .semibold : .regular))
                                .lineLimit(1)
                            Text(candidateDetail(candidate))
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
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
                                    .foregroundColor(candidate.isPinned ? .yellow : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(candidate.isPinned ? "从自动候选中移除" : "加入自动候选并置顶")
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .help("当前连接可直接用于故障回退")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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
