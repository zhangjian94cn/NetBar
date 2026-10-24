import AppKit
import SwiftUI

struct ClashModeTabView: View {
    @ObservedObject var controller: ClashNetworkModeController
    let applicationFacts: ApplicationPathFacts?
    @State private var showsDiagnostics = false
    @State private var showsExplanation = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: PopoverVisualStyle.blockSpacing) {
                hero
                configurationFacts
                probeSection
                diagnosticsDisclosure
                PopoverDisclosure(icon: "info.circle", title: "管理方式与验证范围", isExpanded: $showsExplanation) { explanation }


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
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 16, weight: .medium)).foregroundColor(PopoverVisualStyle.accent)
                .frame(width: 34, height: 34)
                .background(PopoverVisualStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("当前代理策略").font(PopoverVisualStyle.Typography.caption).foregroundColor(.secondary)
                Text(controller.snapshot.headline).font(.system(size: 15, weight: .semibold))
                Text("Clash 原生管理 · NetBar 只读").font(PopoverVisualStyle.Typography.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if controller.isRefreshing { ProgressView().controlSize(.small) }
        }.padding(.vertical, 4)
    }

    private var explanation: some View {
        Text(modeExplanation)
            .font(PopoverVisualStyle.Typography.caption)
            .foregroundColor(PopoverVisualStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var configurationFacts: some View {
        VStack(spacing: 0) {
            PopoverFactRow(title: "TUN", value: boolText(controller.snapshot.runtime?.tunEnabled))
            Divider()
            PopoverFactRow(title: "系统代理", value: boolText(controller.snapshot.runtime?.systemProxyEnabled))
            Divider()
            PopoverFactRow(title: controller.snapshot.mode == .companyCoexistence ? "Claude 组节点" : "代理组节点",
                           value: controller.snapshot.selectedNode ?? "待检测")
            Divider()
            PopoverFactRow(title: "DNS 策略", value: controller.snapshot.configurationMatches ? "配置符合" : "未核对 / 存在差异")
        }
        .padding(.horizontal, PopoverVisualStyle.cardPadding)
        .padding(.vertical, 3).popoverSurface()
    }

    private var probeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if controller.isProbing { ProgressView().controlSize(.mini) }
                else { PopoverStatusDot(state: displayState.factState, diameter: 6) }
                Text(displayState.title).font(PopoverVisualStyle.Typography.bodyStrong)
                Spacer()
                if let probe = controller.probe ?? controller.previousProbe {
                    Text(probe.sampledAt, style: .time).font(PopoverVisualStyle.Typography.caption).foregroundColor(.secondary)
                }
            }
            Text(controller.probe?.detail ?? "实际 DNS / HTTPS 路径需单独检测。UDP、IPv6与业务结果独立验收。")
                .font(PopoverVisualStyle.Typography.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { controller.detectCurrentNetwork() } label: {
                    Text(controller.isProbing ? "正在检测…" : "检测当前网络")
                        .font(PopoverVisualStyle.Typography.bodyStrong)
                        .frame(maxWidth: .infinity, minHeight: 29)
                        .foregroundColor(PopoverVisualStyle.accent)
                        .background(PopoverVisualStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }.disabled(controller.isProbing || controller.isRefreshing)
                Button { openClash() } label: {
                    Label("打开 Clash", systemImage: "arrow.up.right")
                        .font(PopoverVisualStyle.Typography.body)
                        .frame(maxWidth: .infinity, minHeight: 29)
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                        .background(PopoverVisualStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                }
            }.buttonStyle(.plain)
        }.padding(.vertical, 3)
    }

    private var displayState: ProbeDisplayState {
        .resolve(snapshot: controller.snapshot, probe: controller.probe, previous: controller.previousProbe, running: controller.isProbing)
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
    private func openClash() {
        let applications = ["/Applications/Clash Verge.app", "/Applications/Clash Verge Rev.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Clash Verge.app").path]
        guard let path = applications.first(where: FileManager.default.fileExists(atPath:)) else { return }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
