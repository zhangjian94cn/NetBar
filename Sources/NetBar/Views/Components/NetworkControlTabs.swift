import AppKit
import SwiftUI

struct ClashModeTabView: View {
    @ObservedObject var controller: ClashNetworkModeController
    let applicationFacts: ApplicationPathFacts?
    @State private var showsDiagnostics = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: PopoverVisualStyle.blockSpacing) {
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
            .padding(.vertical, PopoverVisualStyle.Spacing.sm)
        }
        .onAppear { controller.refresh() }
        .help("模式只在点击后切换；退出 NetBar 只恢复 DNS。")
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: PopoverVisualStyle.Spacing.sm) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(PopoverVisualStyle.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.snapshot.headline)
                    .font(PopoverVisualStyle.Typography.section)
                Text(controller.snapshot.phase)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
            }
            Spacer()
            if controller.isSwitching || controller.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                PopoverStatusDot(state: healthState)
            }
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            modeButton(.companyCoexistence, icon: "building.2")
            modeButton(.unifiedEgress, icon: "globe")
            modeButton(.originalNetwork, icon: "network")
        }
        .popoverSegmentedTrack()
    }

    private func modeButton(_ mode: ClashNetworkMode, icon: String) -> some View {
        PopoverSegmentedOption(
            title: mode.displayName,
            icon: icon,
            isSelected: controller.snapshot.mode == mode,
            isEnabled: !controller.isSwitching && !controller.isRefreshing
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
            PopoverFactRow(title: "当前配置", value: controller.snapshot.mode?.displayName ?? "其他配置 / 待检测")
            Divider()
            PopoverFactRow(title: "TUN", value: boolText(controller.snapshot.runtime?.tunEnabled))
            Divider()
            PopoverFactRow(title: "系统代理", value: boolText(controller.snapshot.runtime?.systemProxyEnabled))
            Divider()
            PopoverFactRow(title: "DNS", value: controller.snapshot.dns.displayName,
                           state: controller.snapshot.dns.ownedByThisProcess ? .ok : .warning)
            Divider()
            PopoverFactRow(title: "出口核验", value: controller.snapshot.verified ? "本次切换已核验" : "待核验",
                           state: controller.snapshot.verified ? .ok : .unknown)
            HStack {
                Button("刷新状态") { controller.refresh() }
                Spacer()
                Button("安装 / 更新恢复组件") { controller.installDNSRecoveryComponent() }
            }
            .buttonStyle(.link)
            .font(PopoverVisualStyle.Typography.caption)
            .padding(.vertical, PopoverVisualStyle.Spacing.sm)
            .disabled(controller.isSwitching || controller.isRefreshing)
        }
        .padding(.horizontal, PopoverVisualStyle.cardPadding)
        .popoverSurface()
    }

    private func boolText(_ enabled: Bool?) -> String {
        guard let enabled else { return "待检测" }
        return enabled ? "已开启" : "未开启"
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
        .padding(.horizontal, PopoverVisualStyle.cardPadding)
        .popoverSurface()
    }

    private func reachabilityText(_ ready: Bool?) -> String {
        guard let ready else { return "待检测" }
        return ready ? "可达" : "不可达"
    }

    private var modeExplanation: String {
        if controller.snapshot.mode == .originalNetwork {
            return "TUN 与系统代理已关闭，DNS 恢复原设置，Clash 应用继续运行。"
        }
        return "退出 NetBar 时恢复它接管的 DNS，Clash 保持当前状态。重新打开后，选择模式才会接管 DNS。统一出口前请手动断开公司 VPN。"
    }

    private var healthState: PopoverFactState {
        controller.snapshot.verified ? .ok : (controller.isSwitching ? .unknown : .warning)
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
