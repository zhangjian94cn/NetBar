import AppKit
import SwiftUI

private enum NetworkControlTab: String, CaseIterable {
    case underlay
    case overlay

    var title: String {
        switch self {
        case .underlay: return "网络出口"
        case .overlay: return "Clash 模式"
        }
    }

    var icon: String {
        switch self {
        case .underlay: return "arrow.triangle.branch"
        case .overlay: return "shield.lefthalf.filled"
        }
    }
}

struct NetworkControlTabs: View {
    @ObservedObject var networkController: NetworkModeController
    @ObservedObject var overlayController: ClashOverlayModeController
    @State private var selectedTab: NetworkControlTab = .underlay

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            endToEndSummary
                .padding(.horizontal, 16)
                .padding(.top, 10)

            tabSelector
                .padding(.horizontal, 16)

            Group {
                switch selectedTab {
                case .underlay:
                    NetworkModeCard(controller: networkController)
                case .overlay:
                    ClashModeCard(controller: overlayController)
                }
            }
        }
    }

    private var endToEndSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(summaryColor)
                    .frame(width: 7, height: 7)
                Text(summaryStatus)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("当前出口：\(outletText)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Label("Clash：\(overlayModeText)", systemImage: "shield")
                Label("DNS：\(dnsText)", systemImage: "server.rack")
                if let reasonText {
                    Text(reasonText)
                        .lineLimit(1)
                        .help(reasonText)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(summaryColor.opacity(0.08))
        )
    }

    private var tabSelector: some View {
        HStack(spacing: 4) {
            ForEach(NetworkControlTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                    if tab == .overlay { overlayController.refresh() }
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 25)
                        .foregroundColor(selectedTab == tab ? .primary : .secondary)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedTab == tab ? Color.primary.opacity(0.14) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var isOnline: Bool {
        networkController.connectivityProofLevel == .activeVerified && overlayController.snapshot.dataPlaneReady
    }

    private var summaryStatus: String {
        if isOnline { return "在线" }
        if networkController.connectivityProofLevel == .degradedActive { return "受限在线" }
        return "正在恢复"
    }

    private var summaryColor: Color {
        isOnline ? .green : .orange
    }

    private var dnsText: String {
        networkController.dnsPathFacts?.dependency.displayName ?? "待检测"
    }

    private var outletText: String {
        switch networkController.snapshot?.effectiveMode {
        case .macMiniGateway: return "Mac mini"
        case .localWiFi: return "Wi-Fi"
        case nil: return "未验证"
        }
    }

    private var overlayModeText: String {
        overlayController.snapshot.mode?.displayName ?? "检测中"
    }

    private var reasonText: String? {
        if networkController.requiresManualRecovery { return "需要手动恢复路由" }
        if let error = networkController.errorMessage, !error.isEmpty { return error }
        if let reason = overlayController.snapshot.reason, !reason.isEmpty { return reason }
        return networkController.policyMessage
    }
}

private struct ClashModeCard: View {
    @ObservedObject var controller: ClashOverlayModeController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Clash 模式", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if controller.isSwitching {
                    ProgressView().controlSize(.small)
                    Text("正在验证")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } else {
                    Text(controller.snapshot.health.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(healthColor)
                }
            }

            HStack(spacing: 8) {
                modeButton(.systemProxy, icon: "network")
                modeButton(.tunFull, icon: "point.3.connected.trianglepath.dotted")
            }

            Text(modeExplanation)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                fact("持久配置", controller.snapshot.persistentTunEnabled.map { $0 ? "TUN" : "代理" } ?? "未知")
                fact("Runtime", controller.snapshot.runtimeTunEnabled.map { $0 ? "TUN" : "代理" } ?? "未知")
                fact("系统代理", controller.snapshot.systemProxyEnabled ? "开启" : "关闭")
            }

            if let reason = controller.snapshot.reason, !reason.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(reason).lineLimit(3)
                    Spacer(minLength: 4)
                    Button("打开 Clash") { openClash() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 9))
                .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { controller.refresh() }
        .help("模式只会在你点击后切换。Mac mini 与 Wi-Fi 故障转移不会自动开关 TUN，也不会重启 Clash。")
    }

    private func modeButton(_ mode: ClashOverlayMode, icon: String) -> some View {
        let selected = controller.snapshot.mode == mode
        return Button {
            controller.switchMode(to: mode)
        } label: {
            Label(mode.displayName, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selected ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 27)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .disabled(controller.isSwitching)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).foregroundColor(.secondary)
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeExplanation: String {
        switch controller.snapshot.mode {
        case .systemProxy:
            return "更稳定：关闭 TUN，但保持 Clash 与系统代理在线。"
        case .tunFull:
            return "覆盖更多流量：保持共存排除规则，出口变化后只刷新旧连接。"
        case nil:
            return "NetBar 不会随网络切换自动改变此模式。"
        }
    }

    private var healthColor: Color {
        switch controller.snapshot.health {
        case .ready: return .green
        case .switching: return .secondary
        case .unavailable, .configurationDrift, .degraded: return .orange
        }
    }

    private func openClash() {
        let applications = ["/Applications/Clash Verge.app", "/Applications/Clash Verge Rev.app"]
        guard let path = applications.first(where: FileManager.default.fileExists(atPath:) ) else { return }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
