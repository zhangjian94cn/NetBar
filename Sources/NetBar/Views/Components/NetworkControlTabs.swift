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
        .help("请在 Clash 原生界面切换；退出 NetBar 不改变网络。")
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
            if controller.isProbing || controller.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                PopoverStatusDot(state: healthState)
            }
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
            PopoverFactRow(title: "节点", value: controller.snapshot.selectedNode ?? "待检测")
            Divider()
            PopoverFactRow(title: "DNS 策略", value: controller.snapshot.configurationMatches ? "配置符合 · 路径待独立检测" : "未核对 / 存在差异")
            Divider()
            PopoverFactRow(title: "最近检测", value: probeSummary,
                           state: controller.freshProbe?.passed == true ? .ok : .unknown)
            if let detail = controller.probe?.detail {
                Text(detail).font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("刷新状态") { controller.refresh() }
                Spacer()
                Button("检测当前网络") { controller.detectCurrentNetwork() }
                Spacer()
                Button("打开 Clash") { openClash() }
            }
            .buttonStyle(.link)
            .font(PopoverVisualStyle.Typography.caption)
            .padding(.vertical, PopoverVisualStyle.Spacing.sm)
            .disabled(controller.isProbing || controller.isRefreshing)
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
        "请在 Clash 中切换配置、TUN 与系统代理。统一出口前手动断开公司 VPN。NetBar 只读，启动或退出均不改变网络；极端崩溃后重开 Clash 再关闭 TUN。"
    }
    private var probeSummary: String {
        guard let probe = controller.probe else { return "尚未检测" }
        let time = probe.sampledAt.formatted(date: .omitted, time: .shortened)
        guard controller.freshProbe != nil else { return time + " · 已失效" }
        return time + (probe.passed ? " · DNS / HTTPS 通过" : " · 未通过")
    }
    private var healthState: PopoverFactState {
        controller.freshProbe?.passed == true ? .ok : .unknown
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
