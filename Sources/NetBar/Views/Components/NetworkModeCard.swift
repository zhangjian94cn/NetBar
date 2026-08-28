import AppKit
import SwiftUI

struct NetworkModeCard: View {
    @ObservedObject var controller: NetworkModeController
    @State private var showsWiFiCandidates = false
    @State private var showsApplicationDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundColor(statusColor)
                Text("Mac mini 链路")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if controller.isSwitching || controller.isProvisioning {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.isProvisioning ? "正在初始化" : "正在切换")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Text(modeText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(statusColor)
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(linkText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text(addressText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    evidenceItem(
                        title: "固定管理链路",
                        value: managementEvidenceText,
                        healthy: managementEvidenceReady
                    )
                    evidenceItem(
                        title: "雷雳共享出口",
                        value: sharingOutletEvidenceText,
                        healthy: controller.snapshot?.gatewayState == .ready
                    )
                }
                HStack(spacing: 10) {
                    evidenceItem(
                        title: "热点 AP",
                        value: hotspotAPEvidenceText,
                        healthy: controller.miniHelperStatus?.hotspotAPActive == true
                    )
                    evidenceItem(
                        title: "客户端证据",
                        value: hotspotClientEvidenceText,
                        healthy: controller.miniHelperStatus?.hotspotClientObserved == true
                    )
                }
            }

            HStack(spacing: 5) {
                Text("当前出口")
                    .foregroundColor(.secondary)
                Text(currentOutletText)
                    .fontWeight(.semibold)
                Spacer()
                Text(controller.failoverPhase.displayName)
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 9))

            HStack(spacing: 8) {
                modeButton(.macMiniGateway, icon: "desktopcomputer")
                modeButton(.localWiFi, icon: "wifi")
            }

            if let policyMessage = controller.policyMessage, !policyMessage.isEmpty {
                Text(policyMessage)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                evidenceItem(
                    title: "DNS 独立性",
                    value: controller.dnsPathFacts?.dependency.displayName ?? "待检测",
                    healthy: dnsHealthy
                )
                evidenceItem(
                    title: "代理不感知路径",
                    value: proxyUnawareText,
                    healthy: controller.applicationPathFacts?.proxyUnawareHTTPSReady == true
                )
            }

            if controller.dnsPathFacts?.dependency == .miniDependent {
                Button {
                    controller.repairWiFiDNS()
                } label: {
                    HStack(spacing: 6) {
                        if controller.isRepairingDNS { ProgressView().controlSize(.small) }
                        Label("恢复 Wi-Fi 自动 DNS", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isRepairingDNS || controller.snapshot?.effectiveMode != .localWiFi)
                .help("仅在 Wi-Fi 手动 DNS 依赖失联的 192.168.2.1 时可用；失败会恢复原 DNS。")
            }

            Button {
                showsWiFiCandidates.toggle()
                if showsWiFiCandidates { controller.refreshWiFiCandidates() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                    Text("Wi-Fi 候选")
                        .fontWeight(.medium)
                    Text(candidateCountText)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: showsWiFiCandidates ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            if showsWiFiCandidates {
                wifiCandidateList
            }

            Button {
                showsApplicationDiagnostics.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stethoscope")
                    Text("应用诊断")
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: showsApplicationDiagnostics ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsApplicationDiagnostics {
                applicationDiagnostics
            }

            if let action = controller.lastClashAction {
                HStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(action)
                    Spacer()
                    Button("打开 Clash") { openClash() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 9))
                .foregroundColor(.orange)
            }

            if shouldOfferProvisioning {
                Button {
                    controller.initializeFixedLink()
                } label: {
                    Label("初始化/修复链路", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 23)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isSwitching || controller.isProvisioning)
            }

            if !controller.miniGuardianAvailable && !shouldOfferProvisioning {
                Button {
                    controller.initializeFixedLink()
                } label: {
                    Label("安装/更新 Mini 自愈组件", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 23)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isSwitching || controller.isProvisioning)
            }

            if !controller.automationHelperAvailable {
                Button {
                    controller.installAutomationHelper()
                } label: {
                    Label("安装自动切换组件", systemImage: "lock.shield")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 23)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let message = controller.errorMessage, !message.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: controller.requiresManualRecovery ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    Text(message)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    if controller.requiresManualRecovery {
                        Button("打开网络设置") {
                            openNetworkSettings()
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(controller.requiresManualRecovery ? .red : .orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help("切换的是 Wi-Fi 与雷雳网桥的物理出口优先级，不会关闭 Clash、aTrust、Tailscale 或其他 VPN。")
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

    private var applicationDiagnostics: some View {
        let facts = controller.applicationPathFacts
        return VStack(alignment: .leading, spacing: 4) {
            diagnosticRow("系统 HTTPS", ready: facts?.systemProxyAwareHTTPSReady)
            diagnosticRow("显式 Clash HTTPS", ready: facts?.explicitClashHTTPSReady)
            diagnosticRow("ZCode 后台链路", ready: facts?.zcodeDiagnosticReady)
            if let code = facts?.zcodeHTTPStatus {
                Text("ZCode 匿名 HTTP 状态：\(code)（2xx–4xx 表示链路可达）")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func diagnosticRow(_ title: String, ready: Bool?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ready == true ? "可达" : (ready == false ? "不可达" : "待检测"))
                .foregroundColor(ready == true ? .green : .orange)
        }
        .font(.system(size: 9))
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

    private func openClash() {
        let applications = [
            "/Applications/Clash Verge.app",
            "/Applications/Clash Verge Rev.app"
        ]
        if let path = applications.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}
