import AppKit
import SwiftUI

struct ClashModeTabView: View {
    @ObservedObject var controller: ClashOverlayModeController
    let applicationFacts: ApplicationPathFacts?
    @State private var showsDiagnostics = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.md) {
                hero
                modeSelector
                explanation
                configurationFacts
                diagnosticsDisclosure

                if let reason = controller.snapshot.reason, !reason.isEmpty {
                    PopoverBanner(message: reason) {
                        Button("打开 Clash") { openClash() }
                            .buttonStyle(.link)
                            .font(PopoverVisualStyle.Typography.caption)
                    }
                }
            }
            .padding(.horizontal, PopoverVisualStyle.contentInset)
            .padding(.vertical, PopoverVisualStyle.Spacing.md)
        }
        .onAppear { controller.refresh() }
        .help("Clash 模式只会在你点击后切换；网络故障转移不会自动开关 TUN。")
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: PopoverVisualStyle.Spacing.sm) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(PopoverVisualStyle.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.snapshot.mode?.displayName ?? "正在检测 Clash")
                    .font(PopoverVisualStyle.Typography.section)
                Text(controller.snapshot.health.displayName)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
            }
            Spacer()
            if controller.isSwitching {
                ProgressView().controlSize(.small)
            } else {
                PopoverStatusDot(state: healthState)
            }
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            modeButton(.systemProxy, icon: "network")
            modeButton(.tunFull, icon: "point.3.connected.trianglepath.dotted")
        }
        .popoverSegmentedTrack()
    }

    private func modeButton(_ mode: ClashOverlayMode, icon: String) -> some View {
        PopoverSegmentedOption(
            title: mode.displayName,
            icon: icon,
            isSelected: controller.snapshot.mode == mode,
            isEnabled: !controller.isSwitching
        ) {
            controller.switchMode(to: mode)
        }
    }

    private var explanation: some View {
        Text(modeExplanation)
            .font(PopoverVisualStyle.Typography.caption)
            .foregroundColor(PopoverVisualStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var configurationFacts: some View {
        VStack(spacing: 0) {
            PopoverFactRow(title: "持久配置", value: tunText(controller.snapshot.persistentTunEnabled))
            Divider()
            PopoverFactRow(title: "Runtime", value: tunText(controller.snapshot.runtimeTunEnabled))
            Divider()
            PopoverFactRow(title: "系统代理", value: controller.snapshot.systemProxyEnabled ? "已开启" : "未开启")
            Divider()
            PopoverFactRow(
                title: "共存基线",
                value: controller.snapshot.coexistenceBaselineReady ? "完整" : "需要修复",
                state: controller.snapshot.coexistenceBaselineReady ? .ok : .warning
            )
        }
        .padding(.horizontal, PopoverVisualStyle.Spacing.md)
        .popoverSurface()
    }

    private func tunText(_ enabled: Bool?) -> String {
        guard let enabled else { return "待检测" }
        return enabled ? "TUN" : "系统代理"
    }

    private var diagnosticsDisclosure: some View {
        PopoverDisclosure(
            icon: "stethoscope",
            title: "应用兼容性诊断",
            isExpanded: $showsDiagnostics
        ) {
            VStack(spacing: 0) {
                Divider()
                PopoverFactRow(
                    title: "系统 HTTPS",
                    value: reachabilityText(applicationFacts?.systemProxyAwareHTTPSReady),
                    state: PopoverFactState(ready: applicationFacts?.systemProxyAwareHTTPSReady),
                    compact: true
                )
                PopoverFactRow(
                    title: "显式 Clash HTTPS",
                    value: reachabilityText(applicationFacts?.explicitClashHTTPSReady),
                    state: PopoverFactState(ready: applicationFacts?.explicitClashHTTPSReady),
                    compact: true
                )
                PopoverFactRow(
                    title: "代理不感知 / TUN",
                    value: reachabilityText(applicationFacts?.proxyUnawareHTTPSReady),
                    state: PopoverFactState(ready: applicationFacts?.proxyUnawareHTTPSReady),
                    compact: true
                )
                PopoverFactRow(
                    title: "ZCode 后台链路",
                    value: reachabilityText(applicationFacts?.zcodeDiagnosticReady),
                    state: PopoverFactState(ready: applicationFacts?.zcodeDiagnosticReady),
                    compact: true
                )
                if let code = applicationFacts?.zcodeHTTPStatus {
                    Text("ZCode 匿名 HTTP 状态 \(code)，2xx–4xx 表示传输可达。")
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, PopoverVisualStyle.Spacing.xs)
                }
            }
        }
        .padding(.horizontal, PopoverVisualStyle.Spacing.md)
        .popoverSurface()
    }

    private func reachabilityText(_ ready: Bool?) -> String {
        guard let ready else { return "待检测" }
        return ready ? "可达" : "不可达"
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

    private var healthState: PopoverFactState {
        switch controller.snapshot.health {
        case .ready: return .ok
        case .switching: return .unknown
        case .unavailable, .configurationDrift, .degraded: return .warning
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
