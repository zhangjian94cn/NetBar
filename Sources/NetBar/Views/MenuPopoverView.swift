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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Image(systemName: "network")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("NetBar")
                .font(.system(size: 16, weight: .bold))
            Spacer()
            Button(action: refreshSelectedSection) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
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
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundColor(.secondary)
            .help("设置与退出")
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                statusValue(
                    title: nil,
                    value: statusPresentation.connectivity.displayName,
                    icon: "circle.fill",
                    tint: statusColor
                )
                stripDivider
                statusValue(title: "出口", value: statusPresentation.outletText, icon: nil, tint: statusColor)
                stripDivider
                statusValue(title: "Clash", value: statusPresentation.clashText, icon: "shield.lefthalf.filled", tint: statusColor)
                stripDivider
                statusValue(title: "DNS", value: statusPresentation.dnsText, icon: "globe", tint: dnsColor)
            }

            if statusPresentation.connectivity != .online,
               let reason = statusPresentation.primaryReason {
                Text(reason)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(statusColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 9)
    }

    private func statusValue(title: String?, value: String, icon: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: icon == "circle.fill" ? 7 : 9, weight: .semibold))
                    .foregroundColor(tint)
            }
            if let title {
                Text(title)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 9))
    }

    private var stripDivider: some View {
        Divider().frame(height: 14)
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
        HStack(spacing: 4) {
            ForEach(availableSections, id: \.self) { section in
                Button {
                    selectedSection = section
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 24, height: 19)
                            if tabNeedsAttention(section) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 2, y: -1)
                            }
                        }
                        Text(section.title)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(selectedSection == section ? tabAccentColor(section) : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selectedSection == section ? Color.primary.opacity(0.08) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tabAccentColor(_ section: PopoverSection) -> Color {
        switch section {
        case .outlet: return .green
        case .clash: return .indigo
        case .applications: return .blue
        case .monitoring: return .cyan
        }
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
        switch statusPresentation.tone {
        case .positive: return .green
        case .caution: return .orange
        case .negative: return .red
        case .neutral: return .secondary
        }
    }

    private var dnsColor: Color {
        statusPresentation.monitoringNeedsAttention ? .orange : .green
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
            Divider().padding(.horizontal, 16)
            trafficSelector
                .padding(.horizontal, 16)
                .padding(.vertical, 9)

            if selectedTrafficTab == 0 {
                TrafficTable(
                    isEmpty: processTrafficMonitor.appSpeeds.isEmpty,
                    emptyText: L10n.Table.noActiveApps,
                    bodyHeight: 230
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
                        bodyHeight: 202
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
        HStack(spacing: 16) {
            speedValue(
                title: L10n.Speed.download,
                value: networkMonitor.currentSpeed.formattedDownload,
                icon: "arrow.down.circle.fill",
                color: .blue
            )
            Divider().frame(height: 31)
            speedValue(
                title: L10n.Speed.upload,
                value: networkMonitor.currentSpeed.formattedUpload,
                icon: "arrow.up.circle.fill",
                color: .green
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func speedValue(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .symbolRenderingMode(.hierarchical)
                .tint(color)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var trafficSelector: some View {
        HStack(spacing: 0) {
            trafficButton(title: L10n.Tab.realtime, icon: "bolt.fill", tag: 0, color: .orange)
            trafficButton(title: L10n.Tab.cumulative, icon: "chart.bar.fill", tag: 1, color: .blue)
        }
        .padding(2)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func trafficButton(title: String, icon: String, tag: Int, color: Color) -> some View {
        Button {
            selectedTrafficTab = tag
            if tag == 1 { processTrafficMonitor.requestCumulativeRefresh() }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selectedTrafficTab == tag ? .primary : .secondary)
                .symbolRenderingMode(.hierarchical)
                .tint(color)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selectedTrafficTab == tag ? Color.primary.opacity(0.14) : Color.clear)
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
        VStack(spacing: 0) {
            factRow("当前物理出口", value: statusPresentation.outletText, icon: "arrow.triangle.branch")
            Divider().padding(.leading, 24)
            factRow(
                "Wi-Fi",
                value: NetworkIdentityFormatter.wifiText(
                    ssid: networkInfoProvider.wifiSSID,
                    hideWiFiName: appConfig.hideWiFiName
                ),
                icon: "wifi"
            )
            Divider().padding(.leading, 24)
            factRow("局域网地址", value: networkInfoProvider.localIP, icon: "pc", monospaced: true)
            Divider().padding(.leading, 24)
            factRow("DNS", value: dnsFacts?.dependency.displayName ?? "DNS 待检测", icon: "server.rack")
        }
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func factRow(_ title: String, value: String, icon: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 9, weight: .medium, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 30)
    }
}
