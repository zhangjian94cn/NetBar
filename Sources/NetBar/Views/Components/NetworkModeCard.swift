import AppKit
import SwiftUI

struct NetworkModeCard: View {
    @ObservedObject var controller: NetworkModeController

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
                Text(mode.displayName)
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
        controller.snapshot?.effectiveMode?.displayName ?? "待检测"
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
}
