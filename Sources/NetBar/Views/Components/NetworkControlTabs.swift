import AppKit
import SwiftUI

struct ClashModeTabView: View {
    @ObservedObject var controller: ClashOverlayModeController
    let applicationFacts: ApplicationPathFacts?
    @State private var showsDiagnostics = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                hero
                modeSelector
                explanation
                configurationFacts
                diagnosticsDisclosure

                if let reason = controller.snapshot.reason, !reason.isEmpty {
                    warningRow(reason)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { controller.refresh() }
        .help("Clash 模式只会在你点击后切换；网络故障转移不会自动开关 TUN。")
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(healthColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.snapshot.mode?.displayName ?? "正在检测 Clash")
                    .font(PopoverVisualStyle.Typography.section)
                Text(controller.snapshot.health.displayName)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if controller.isSwitching {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(healthColor)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            modeButton(.systemProxy, icon: "network")
            modeButton(.tunFull, icon: "point.3.connected.trianglepath.dotted")
        }
        .padding(3)
        .background(PopoverVisualStyle.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func modeButton(_ mode: ClashOverlayMode, icon: String) -> some View {
        let selected = controller.snapshot.mode == mode
        return PopoverSegmentedOption(
            title: mode.displayName,
            icon: icon,
            isSelected: selected,
            isEnabled: !controller.isSwitching,
            accent: PopoverVisualStyle.warning
        ) {
            controller.switchMode(to: mode)
        }
    }

    private var explanation: some View {
        Text(modeExplanation)
            .font(PopoverVisualStyle.Typography.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var configurationFacts: some View {
        VStack(spacing: 0) {
            factRow("持久配置", value: controller.snapshot.persistentTunEnabled.map { $0 ? "TUN" : "系统代理" } ?? "未知")
            Divider().padding(.leading, 20)
            factRow("Runtime", value: controller.snapshot.runtimeTunEnabled.map { $0 ? "TUN" : "系统代理" } ?? "未知")
            Divider().padding(.leading, 20)
            factRow("系统代理", value: controller.snapshot.systemProxyEnabled ? "已开启" : "未开启")
            Divider().padding(.leading, 20)
            factRow("共存基线", value: controller.snapshot.coexistenceBaselineReady ? "完整" : "需要修复")
        }
        .padding(.horizontal, 12)
        .popoverGroup()
    }

    private func factRow(_ name: String, value: String) -> some View {
        HStack {
            Text(name)
                .foregroundColor(PopoverVisualStyle.secondaryText)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundColor(PopoverVisualStyle.primaryText)
        }
        .font(PopoverVisualStyle.Typography.caption)
        .frame(minHeight: 32)
    }

    private var diagnosticsDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                showsDiagnostics.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "stethoscope")
                        .frame(width: 16)
                    Text("应用兼容性诊断")
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: showsDiagnostics ? "chevron.down" : "chevron.right")
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                }
                .font(PopoverVisualStyle.Typography.body)
                .foregroundColor(PopoverVisualStyle.primaryText)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDiagnostics {
                Divider().padding(.leading, 22)
                VStack(spacing: 5) {
                    diagnosticRow("系统 HTTPS", ready: applicationFacts?.systemProxyAwareHTTPSReady)
                    diagnosticRow("显式 Clash HTTPS", ready: applicationFacts?.explicitClashHTTPSReady)
                    diagnosticRow("代理不感知 / TUN", ready: applicationFacts?.proxyUnawareHTTPSReady)
                    diagnosticRow("ZCode 后台链路", ready: applicationFacts?.zcodeDiagnosticReady)
                    if let code = applicationFacts?.zcodeHTTPStatus {
                        Text("ZCode 匿名 HTTP 状态：\(code)（2xx–4xx 表示传输可达）")
                            .font(PopoverVisualStyle.Typography.caption)
                            .foregroundColor(PopoverVisualStyle.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .popoverGroup()
    }

    private func diagnosticRow(_ title: String, ready: Bool?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ready == true ? "可达" : (ready == false ? "不可达" : "待检测"))
                .foregroundColor(ready == true ? PopoverVisualStyle.healthy : PopoverVisualStyle.warning)
        }
        .font(PopoverVisualStyle.Typography.caption)
    }

    private func warningRow(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(reason)
                .lineLimit(3)
            Spacer(minLength: 4)
            Button("打开 Clash") { openClash() }
                .buttonStyle(.link)
        }
        .font(PopoverVisualStyle.Typography.caption)
        .foregroundColor(PopoverVisualStyle.warning)
        .padding(10)
        .background(PopoverVisualStyle.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var modeExplanation: String {
        switch controller.snapshot.mode {
        case .systemProxy:
            return "更稳定：关闭 TUN，但保持 Clash 与系统代理在线；不遵循系统代理的后台程序可能无法联网。"
        case .tunFull:
            return "覆盖更多程序：保持共存排除规则，物理出口变化后只刷新旧连接，不重启 Clash。"
        case nil:
            return "NetBar 不会随 Mac mini 与 Wi-Fi 切换自动改变此模式。"
        }
    }

    private var healthColor: Color {
        switch controller.snapshot.health {
        case .ready: return PopoverVisualStyle.healthy
        case .switching: return .secondary
        case .unavailable, .configurationDrift, .degraded: return PopoverVisualStyle.warning
        }
    }

    private func openClash() {
        let applications = ["/Applications/Clash Verge.app", "/Applications/Clash Verge Rev.app"]
        guard let path = applications.first(where: FileManager.default.fileExists(atPath:)) else { return }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
