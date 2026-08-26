import AppKit
import SwiftUI

struct NetworkModeCard: View {
    @ObservedObject var controller: NetworkModeController
    @State private var showsWiFiCandidates = false

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

            HStack(spacing: 6) {
                Text("目标：\(controller.routePreference.displayName)")
                Spacer()
                Text("当前：\(currentOutletText)")
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Text("阶段：\(controller.failoverPhase.displayName)")
                Spacer()
                if let candidate = controller.activeCandidateName {
                    Text("候选：\(candidate)")
                        .lineLimit(1)
                }
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)

            if let policyMessage = controller.policyMessage, !policyMessage.isEmpty {
                Text(policyMessage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(statusColor)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                modeButton(.localWiFi, icon: "wifi")
                modeButton(.macMiniGateway, icon: "desktopcomputer")
            }

            HStack(spacing: 8) {
                Button {
                    controller.useWiFiNow()
                } label: {
                    Label("立即用 Wi-Fi", systemImage: "wifi.exclamationmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 23)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isSwitching || controller.isProvisioning)

                Button {
                    showsWiFiCandidates.toggle()
                    if showsWiFiCandidates { controller.refreshWiFiCandidates() }
                } label: {
                    Label("Wi-Fi 候选", systemImage: showsWiFiCandidates ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 23)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if showsWiFiCandidates {
                wifiCandidateList
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

        return Button {
            controller.switchMode(to: mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode == .macMiniGateway ? "自动（Mini 优先）" : "固定 Wi-Fi")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 25)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
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
                Text(controller.wifiLocationAccess.displayName)
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
                Text("没有符合条件的已保存 Wi-Fi；请先在系统 Wi-Fi 菜单连接并置顶。")
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
                        if candidate.isPinned {
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
                        Button {
                            controller.setWiFiCandidate(candidate.displayName, pinned: !candidate.isPinned)
                        } label: {
                            Image(systemName: candidate.isPinned ? "star.fill" : "star")
                                .foregroundColor(candidate.isPinned ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(candidate.isPinned ? "从自动候选中移除" : "加入自动候选并置顶")
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
