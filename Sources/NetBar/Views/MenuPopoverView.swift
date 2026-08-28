import Cocoa
import SwiftUI

struct MenuPopoverView: View {
    private let maxTableApps = 20

    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject var proxyDetector: ProxyDetector
    @ObservedObject var processTrafficMonitor: ProcessTrafficMonitor
    @ObservedObject var networkInfoProvider: NetworkInfoProvider
    @ObservedObject var egressIPMonitor: EgressIPMonitor
    @ObservedObject var vpsTrafficMonitor: VPSTrafficMonitor
    @ObservedObject var appIconResolver: AppIconResolver
    @ObservedObject var networkModeController: NetworkModeController
    @ObservedObject var clashOverlayModeController: ClashOverlayModeController
    @ObservedObject private var appConfig = AppConfig.shared
    let coordinator: MonitorCoordinator

    @State private var selectedSection = AppConfig.shared.selectedPopoverSection
    @State private var selectedTrafficTab = 0

    private var availableSections: [PopoverSection] {
        PopoverSection.available(for: DistributionFlavor.current)
    }

    private var statusPresentation: PopoverStatusPresentation {
        PopoverStatusPresentation(
            proofLevel: networkModeController.connectivityProofLevel,
            effectiveMode: networkModeController.snapshot?.effectiveMode,
            overlay: clashOverlayModeController.snapshot,
            dnsFacts: networkModeController.dnsPathFacts,
            primaryReason: primaryReason
        )
    }

    private var primaryReason: String? {
        if networkModeController.requiresManualRecovery {
            return networkModeController.errorMessage ?? "需要手动恢复网络路由"
        }
        return networkModeController.errorMessage ??
            clashOverlayModeController.snapshot.reason ??
            networkModeController.policyMessage
    }

    private var visibleIconNames: [String] {
        guard DistributionFlavor.current.supportsProcessTraffic else { return [] }
        let names = processTrafficMonitor.appSpeeds.prefix(maxTableApps).map(\.name) +
            processTrafficMonitor.cumulativeRanking.prefix(maxTableApps).map(\.name)
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            statusStrip

            Divider().padding(.horizontal, 12)

            contentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if availableSections.count > 1 {
                Divider()
                bottomTabBar
            }
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.shell, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.shell, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.shell, style: .continuous))
        .onAppear {
            normalizeSelectedSection()
            preloadVisibleIcons()
            if DistributionFlavor.current.supportsNetworkModeSwitch {
                networkModeController.beginObserving()
                networkModeController.refresh()
            }
            if DistributionFlavor.current.supportsClashModeSwitch {
                clashOverlayModeController.refresh()
            }
        }
        .onDisappear {
            networkModeController.endObserving()
        }
        .onChange(of: selectedSection) { section in
            appConfig.selectedPopoverSection = section
            refreshOnSelection(section)
        }
        .onChange(of: visibleIconNames) { _ in
            preloadVisibleIcons()
        }
        .onChange(of: networkInfoProvider.wifiSSID) { _ in
            coordinator.scheduleEgressIPRefreshAfterIdentityChange()
        }
        .onChange(of: networkInfoProvider.localIP) { _ in
            coordinator.scheduleEgressIPRefreshAfterIdentityChange()
        }
        .onChange(of: proxyDetector.status) { _ in
            coordinator.scheduleEgressIPRefreshAfterIdentityChange()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            Text("NetBar")
                .font(PopoverVisualStyle.Typography.title)
            Spacer()
            Button(action: refreshSelectedSection) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .frame(width: 24, height: 24)
            .help("刷新当前页面")

            Menu {
                Button("设置…") {
                    SettingsWindowController.shared.show(coordinator: coordinator)
                }
                Divider()
                Button("退出 NetBar") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
            .foregroundColor(.secondary)
            .help("设置与退出")
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusPresentation.connectivity.displayName)
                    .font(PopoverVisualStyle.Typography.section)
                Spacer()
                Text("当前出口：")
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(.secondary)
                Text(statusPresentation.outletText)
                    .font(PopoverVisualStyle.Typography.bodyStrong)
                    .foregroundColor(statusColor)
            }

            HStack(spacing: 12) {
                compactStatus(title: "Clash", value: statusPresentation.clashText, icon: "shield.lefthalf.filled", tint: clashColor)
                compactStatus(title: "DNS", value: statusPresentation.dnsText, icon: "server.rack", tint: dnsColor)
            }

            if statusPresentation.connectivity != .online,
               let reason = statusPresentation.primaryReason {
                Text(reason)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .help(reason)
                .font(PopoverVisualStyle.Typography.caption)
            }
        }
        .padding(11)
        .background(
            PopoverVisualStyle.statusFill(for: statusPresentation.tone),
            in: RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.card, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 9)
    }

    private func compactStatus(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
            Text("\(title)：").foregroundColor(.secondary)
            Text(value).fontWeight(.medium).lineLimit(1)
        }
        .font(PopoverVisualStyle.Typography.caption)
    }

    @ViewBuilder
    private var contentSection: some View {
        switch selectedSection {
        case .outlet:
            NetworkModeCard(controller: networkModeController)
        case .clash:
            ClashModeTabView(
                controller: clashOverlayModeController,
                applicationFacts: networkModeController.applicationPathFacts
            )
        case .applications:
            ApplicationsTabView(
                networkMonitor: networkMonitor,
                processTrafficMonitor: processTrafficMonitor,
                appIconResolver: appIconResolver,
                selectedTrafficTab: $selectedTrafficTab,
                maxTableApps: maxTableApps
            )
        case .monitoring:
            MonitoringTabView(
                networkInfoProvider: networkInfoProvider,
                egressIPMonitor: egressIPMonitor,
                vpsTrafficMonitor: vpsTrafficMonitor,
                statusPresentation: statusPresentation,
                dnsFacts: networkModeController.dnsPathFacts,
                appConfig: appConfig
            )
        }
    }

    private var bottomTabBar: some View {
        HStack(spacing: 2) {
            ForEach(availableSections, id: \.self) { section in
                Button {
                    selectedSection = section
                } label: {
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 24, height: 19)
                            if tabNeedsAttention(section) {
                                Circle()
                                    .fill(PopoverVisualStyle.warning)
                                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                                    .frame(width: 7, height: 7)
                                    .offset(x: 2, y: -1)
                            }
                        }
                        Text(section.title).font(PopoverVisualStyle.Typography.captionStrong)
                    }
                    .foregroundColor(selectedSection == section ? .primary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedSection == section ? PopoverVisualStyle.selectedFill : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(4)
        .background(PopoverVisualStyle.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
        .padding(.top, 6)
    }

    private func tabNeedsAttention(_ section: PopoverSection) -> Bool {
        if section == .monitoring {
            return statusPresentation.needsAttention(section) ||
                egressIPMonitor.errorMessage != nil ||
                vpsTrafficMonitor.vpsList.contains(where: { $0.error != nil })
        }
        return statusPresentation.needsAttention(section)
    }

    private var statusColor: Color {
        PopoverVisualStyle.color(for: statusPresentation.tone)
    }

    private var dnsColor: Color {
        statusPresentation.monitoringNeedsAttention ? PopoverVisualStyle.warning : PopoverVisualStyle.healthy
    }

    private var clashColor: Color {
        statusPresentation.clashNeedsAttention ? PopoverVisualStyle.warning : PopoverVisualStyle.healthy
    }

    private var connectivityIcon: String {
        switch statusPresentation.connectivity {
        case .online: return "checkmark"
        case .limited: return "exclamationmark"
        case .recovering: return "arrow.triangle.2.circlepath"
        case .offline: return "xmark"
        }
    }

    private func normalizeSelectedSection() {
        guard availableSections.contains(selectedSection) else {
            selectedSection = PopoverSection.defaultSection(for: DistributionFlavor.current)
            return
        }
        appConfig.selectedPopoverSection = selectedSection
    }

    private func refreshOnSelection(_ section: PopoverSection) {
        switch section {
        case .outlet:
            networkModeController.refresh()
        case .clash:
            clashOverlayModeController.refresh()
        case .applications where selectedTrafficTab == 1:
            processTrafficMonitor.requestCumulativeRefresh()
        case .applications, .monitoring:
            break
        }
    }

    private func refreshSelectedSection() {
        proxyDetector.checkProxySettings()
        networkInfoProvider.refresh()
        if DistributionFlavor.current.supportsNetworkModeSwitch {
            networkModeController.refresh()
        }
        if DistributionFlavor.current.supportsClashModeSwitch {
            clashOverlayModeController.refresh()
        }

        switch selectedSection {
        case .outlet:
            networkModeController.refreshWiFiCandidates()
        case .clash:
            break
        case .applications:
            if selectedTrafficTab == 1 {
                processTrafficMonitor.requestCumulativeRefresh()
            }
        case .monitoring:
            egressIPMonitor.refresh(force: true)
            vpsTrafficMonitor.refresh()
        }
    }

    private func preloadVisibleIcons() {
        appIconResolver.preloadIcons(for: visibleIconNames)
    }
}

private struct ApplicationsTabView: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject var processTrafficMonitor: ProcessTrafficMonitor
    @ObservedObject var appIconResolver: AppIconResolver
    @Binding var selectedTrafficTab: Int
    let maxTableApps: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            speedSection
            trafficSelector
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            if selectedTrafficTab == 0 {
                TrafficTable(
                    isEmpty: processTrafficMonitor.appSpeeds.isEmpty,
                    emptyText: L10n.Table.noActiveApps,
                    emptyDetail: "打开应用并产生网络请求后，实时流量会显示在这里。",
                    bodyHeight: 150
                ) {
                    ForEach(Array(processTrafficMonitor.appSpeeds.prefix(maxTableApps))) { app in
                        AppSpeedRow(app: app, iconResolver: appIconResolver)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer()
                        TimePeriodPopUpButton(selection: $processTrafficMonitor.selectedPeriod)
                            .frame(width: 94, height: 22)
                    }
                    TrafficTable(
                        isEmpty: processTrafficMonitor.cumulativeRanking.isEmpty,
                        emptyText: L10n.Table.noTrafficRecords,
                        emptyDetail: "选择时间范围后，累计使用量会显示在这里。",
                        bodyHeight: 128
                    ) {
                        ForEach(Array(processTrafficMonitor.cumulativeRanking.prefix(maxTableApps))) { app in
                            CumulativeRow(app: app, iconResolver: appIconResolver)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var speedSection: some View {
        HStack(spacing: 0) {
            speedValue(
                title: L10n.Speed.download,
                value: networkMonitor.currentSpeed.formattedDownload,
                icon: "arrow.down",
                color: .blue
            )
            Rectangle()
                .fill(PopoverVisualStyle.hairline)
                .frame(width: 1, height: 38)
            speedValue(
                title: L10n.Speed.upload,
                value: networkMonitor.currentSpeed.formattedUpload,
                icon: "arrow.up",
                color: PopoverVisualStyle.healthy
            )
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func speedValue(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.captionStrong)
                .foregroundColor(color)
                .symbolRenderingMode(.hierarchical)
                .tint(color)
            Text(value)
                .font(PopoverVisualStyle.Typography.metric)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var trafficSelector: some View {
        HStack(spacing: 0) {
            trafficButton(title: L10n.Tab.realtime, icon: "bolt.fill", tag: 0)
            trafficButton(title: L10n.Tab.cumulative, icon: "chart.bar.fill", tag: 1)
        }
        .padding(3)
        .frame(height: 34)
        .background(PopoverVisualStyle.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func trafficButton(title: String, icon: String, tag: Int) -> some View {
        Button {
            selectedTrafficTab = tag
            if tag == 1 { processTrafficMonitor.requestCumulativeRefresh() }
        } label: {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.bodyStrong)
                .foregroundColor(selectedTrafficTab == tag ? .primary : .secondary)
                .symbolRenderingMode(.hierarchical)
                .tint(selectedTrafficTab == tag ? PopoverVisualStyle.warning : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selectedTrafficTab == tag ? PopoverVisualStyle.selectedFill : Color.clear)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct MonitoringTabView: View {
    @ObservedObject var networkInfoProvider: NetworkInfoProvider
    @ObservedObject var egressIPMonitor: EgressIPMonitor
    @ObservedObject var vpsTrafficMonitor: VPSTrafficMonitor
    let statusPresentation: PopoverStatusPresentation
    let dnsFacts: DNSPathFacts?
    @ObservedObject var appConfig: AppConfig

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                networkFacts

                if appConfig.ipCheckEnabled {
                    EgressIPCard(monitor: egressIPMonitor)
                }

                ForEach(vpsTrafficMonitor.vpsList) { vps in
                    VPSTrafficCard(vps: vps)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var networkFacts: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                factTile("当前物理出口", value: statusPresentation.outletText, icon: "arrow.triangle.branch")
                factTile(
                    "Wi-Fi",
                    value: NetworkIdentityFormatter.wifiText(
                        ssid: networkInfoProvider.wifiSSID,
                        hideWiFiName: appConfig.hideWiFiName
                    ),
                    icon: "wifi"
                )
            }
            HStack(spacing: 12) {
                factTile("局域网地址", value: networkInfoProvider.localIP, icon: "pc", monospaced: true)
                factTile("DNS", value: dnsFacts?.dependency.displayName ?? "DNS 待检测", icon: "server.rack")
            }
        }
    }

    private func factTile(_ title: String, value: String, icon: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(monospaced ? PopoverVisualStyle.Typography.data : PopoverVisualStyle.Typography.bodyStrong)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
