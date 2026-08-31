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
            primaryReason: primaryReason,
            outletFault: networkModeController.requiresManualRecovery ||
                (networkModeController.errorMessage?.isEmpty == false)
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

            Divider()

            contentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.15), value: selectedSection)

            if availableSections.count > 1 {
                Divider()
                bottomTabBar
            }
        }
        .frame(width: PopoverVisualStyle.Metrics.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.shell, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.shell, style: .continuous)
                .stroke(PopoverVisualStyle.hairline, lineWidth: 0.5)
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

    /// The header carries the overview.
    ///
    /// The previous layout stacked an app wordmark on top of a permanently
    /// tinted status band, so the panel announced an alarm on every open. The
    /// state now lives on one line, and the pages that own a problem show the
    /// actionable banner themselves.
    private var headerSection: some View {
        HStack(spacing: PopoverVisualStyle.Spacing.sm) {
            PopoverStatusDot(state: statusPresentation.tone.factState, diameter: 7)

            Text(statusPresentation.connectivity.displayName)
                .font(PopoverVisualStyle.Typography.title)
                .foregroundColor(PopoverVisualStyle.primaryText)

            Text(statusPresentation.outletText)
                .font(PopoverVisualStyle.Typography.body)
                .foregroundColor(PopoverVisualStyle.secondaryText)
                .lineLimit(1)

            Spacer(minLength: PopoverVisualStyle.Spacing.sm)

            Button(action: refreshSelectedSection) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(PopoverVisualStyle.secondaryText)
            .frame(width: 20, height: 20)
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
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 20, height: 20)
            .foregroundColor(PopoverVisualStyle.secondaryText)
            .help("设置与退出")
        }
        .padding(.horizontal, PopoverVisualStyle.contentInset)
        .padding(.vertical, PopoverVisualStyle.Spacing.xs + 2)
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
                companyVPNMonitor: coordinator.companyVPNDiagnosticMonitor,
                appConfig: appConfig
            )
        }
    }

    /// Tab bar shares the content inset so navigation and content edges align,
    /// and marks selection with the system accent instead of a grey pill that
    /// sat only 0.04 alpha above its own container.
    private var bottomTabBar: some View {
        HStack(spacing: PopoverVisualStyle.Spacing.xs) {
            ForEach(availableSections, id: \.self) { section in
                Button {
                    selectedSection = section
                } label: {
                    tabLabel(section)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(.horizontal, PopoverVisualStyle.contentInset)
        .padding(.vertical, PopoverVisualStyle.Spacing.xs + 2)
    }

    private func tabLabel(_ section: PopoverSection) -> some View {
        let isSelected = selectedSection == section
        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 15)
                if tabNeedsAttention(section) {
                    Circle()
                        .fill(PopoverVisualStyle.warning)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -1)
                }
            }
            Text(section.title).font(PopoverVisualStyle.Typography.captionStrong)
        }
        .foregroundColor(isSelected ? PopoverVisualStyle.accent : PopoverVisualStyle.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background {
            RoundedRectangle(cornerRadius: PopoverVisualStyle.Radius.control, style: .continuous)
                .fill(isSelected ? PopoverVisualStyle.accent.opacity(0.16) : Color.clear)
        }
        .contentShape(Rectangle())
    }

    private func tabNeedsAttention(_ section: PopoverSection) -> Bool {
        if section == .monitoring {
            return statusPresentation.needsAttention(section) ||
                egressIPMonitor.errorMessage != nil ||
                vpsTrafficMonitor.vpsList.contains(where: { $0.error != nil })
        }
        return statusPresentation.needsAttention(section)
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
            coordinator.companyVPNDiagnosticMonitor.refresh()
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
        VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.sm) {
            speedSection
            trafficSelector

            if selectedTrafficTab == 0 {
                TrafficTable(
                    isEmpty: processTrafficMonitor.appSpeeds.isEmpty,
                    emptyText: L10n.Table.noActiveApps,
                    emptyDetail: "打开应用并产生网络请求后，实时流量会显示在这里。"
                ) {
                    ForEach(Array(processTrafficMonitor.appSpeeds.prefix(maxTableApps))) { app in
                        TrafficTableRow(
                            app: app,
                            iconResolver: appIconResolver,
                            downloadText: app.formattedDownload,
                            uploadText: app.formattedUpload,
                            share: PopoverMeter.fraction(app.totalSpeed, of: peakSpeed)
                        )
                    }
                }
            } else {
                HStack {
                    Spacer()
                    TimePeriodPopUpButton(selection: $processTrafficMonitor.selectedPeriod)
                        .frame(width: 94, height: 22)
                }
                TrafficTable(
                    isEmpty: processTrafficMonitor.cumulativeRanking.isEmpty,
                    emptyText: L10n.Table.noTrafficRecords,
                    emptyDetail: "选择时间范围后，累计使用量会显示在这里。"
                ) {
                    ForEach(Array(processTrafficMonitor.cumulativeRanking.prefix(maxTableApps))) { app in
                        TrafficTableRow(
                            app: app,
                            iconResolver: appIconResolver,
                            downloadText: app.formattedCumulativeDown,
                            uploadText: app.formattedCumulativeUp,
                            share: PopoverMeter.fraction(app.totalCumulative, of: peakCumulative)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, PopoverVisualStyle.contentInset)
        .padding(.vertical, PopoverVisualStyle.Spacing.sm)
    }

    private var peakSpeed: Double {
        processTrafficMonitor.appSpeeds.prefix(maxTableApps).map(\.totalSpeed).max() ?? 0
    }

    private var peakCumulative: UInt64 {
        processTrafficMonitor.cumulativeRanking.prefix(maxTableApps).map(\.totalCumulative).max() ?? 0
    }

    private var speedSection: some View {
        VStack(spacing: PopoverVisualStyle.Spacing.xs) {
            HStack(spacing: 0) {
                speedValue(
                    title: L10n.Speed.download,
                    value: networkMonitor.currentSpeed.formattedDownload,
                    icon: "arrow.down"
                )
                Rectangle()
                    .fill(PopoverVisualStyle.hairline)
                    .frame(width: 1, height: 28)
                speedValue(
                    title: L10n.Speed.upload,
                    value: networkMonitor.currentSpeed.formattedUpload,
                    icon: "arrow.up"
                )
            }

            PopoverSparkline(samples: networkMonitor.speedHistory.map(\.total), height: 16)
                .padding(.horizontal, PopoverVisualStyle.Spacing.xs)
        }
    }

    private func speedValue(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: icon)
                .font(PopoverVisualStyle.Typography.captionStrong)
                .foregroundColor(PopoverVisualStyle.secondaryText)
            Text(value)
                .font(PopoverVisualStyle.Typography.metric)
                .foregroundColor(PopoverVisualStyle.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .popoverNumericTransition()
        }
        .frame(maxWidth: .infinity)
    }

    private var trafficSelector: some View {
        HStack(spacing: 0) {
            PopoverSegmentedOption(
                title: L10n.Tab.realtime,
                icon: "bolt.fill",
                isSelected: selectedTrafficTab == 0,
                isEnabled: true
            ) {
                selectedTrafficTab = 0
            }
            PopoverSegmentedOption(
                title: L10n.Tab.cumulative,
                icon: "chart.bar.fill",
                isSelected: selectedTrafficTab == 1,
                isEnabled: true
            ) {
                selectedTrafficTab = 1
                processTrafficMonitor.requestCumulativeRefresh()
            }
        }
        .popoverSegmentedTrack()
    }
}

private struct MonitoringTabView: View {
    @ObservedObject var networkInfoProvider: NetworkInfoProvider
    @ObservedObject var egressIPMonitor: EgressIPMonitor
    @ObservedObject var vpsTrafficMonitor: VPSTrafficMonitor
    let statusPresentation: PopoverStatusPresentation
    let dnsFacts: DNSPathFacts?
    @ObservedObject var companyVPNMonitor: CompanyVPNDiagnosticMonitor
    @ObservedObject var appConfig: AppConfig

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: PopoverVisualStyle.blockSpacing) {
                networkFacts

                if DistributionFlavor.current == .directFull {
                    companyVPNSection
                }

                if appConfig.ipCheckEnabled {
                    EgressIPCard(monitor: egressIPMonitor)
                }

                ForEach(vpsTrafficMonitor.vpsList) { vps in
                    VPSTrafficCard(vps: vps)
                }
            }
            .padding(.horizontal, PopoverVisualStyle.contentInset)
            .padding(.vertical, PopoverVisualStyle.Spacing.sm)
        }
    }

    private var companyVPNSection: some View {
        let snapshot = companyVPNMonitor.snapshot
        let state: PopoverFactState
        switch snapshot.health {
        case .ready: state = .ok
        case .degraded: state = .warning
        case .unavailable: state = .fault
        case .unknown: state = .unknown
        }
        return VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.sm) {
            HStack {
                Image(systemName: "building.2")
                    .foregroundColor(PopoverVisualStyle.secondaryText)
                Text("公司 VPN")
                    .font(PopoverVisualStyle.Typography.section)
                Spacer()
                PopoverStatusDot(state: state)
                Text(snapshot.health == .ready ? "正常" : snapshot.health == .unknown ? "待检测" : "需关注")
                    .font(PopoverVisualStyle.Typography.captionStrong)
            }

            HStack(spacing: PopoverVisualStyle.Spacing.md) {
                PopoverFactTile(
                    title: "aTrust / 企业路由",
                    value: snapshot.aTrustRunning ? "客户端运行" : "未检测到",
                    detail: snapshot.protectedRouteInterface,
                    state: snapshot.aTrustRunning ? .ok : .unknown
                )
                PopoverFactTile(
                    title: "OAVPN 入口",
                    value: snapshot.portalStatus,
                    detail: snapshot.portalEndpoint,
                    state: state
                )
            }

            Text(snapshot.baselineStatus)
                .font(PopoverVisualStyle.Typography.caption)
                .foregroundColor(PopoverVisualStyle.secondaryText)
                .lineLimit(2)

            HStack(spacing: PopoverVisualStyle.Spacing.xs) {
                Text(snapshot.overlayMode)
                    .font(PopoverVisualStyle.Typography.captionStrong)
                if let reason = snapshot.overlayReason {
                    Text("· \(reason)")
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.warning)
                        .lineLimit(2)
                }
            }

            if let message = companyVPNMonitor.errorMessage {
                Text(message)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.warning)
            }

            HStack {
                Button(companyVPNMonitor.isRunningOwnerDiagnostic ? "正在诊断…" : "运行公司 VPN 诊断") {
                    companyVPNMonitor.runOwnerDiagnostic()
                }
                .buttonStyle(.link)
                .disabled(companyVPNMonitor.isRunningOwnerDiagnostic)
                #if !APP_STORE
                if snapshot.recoveryAvailable {
                    Button(companyVPNMonitor.isRecoveringCoexistence ? "正在恢复…" : "恢复公司 VPN + 外网共存") {
                        companyVPNMonitor.requestCoexistenceRecovery()
                    }
                    .buttonStyle(.link)
                    .disabled(
                        companyVPNMonitor.isRecoveringCoexistence ||
                        companyVPNMonitor.isRunningOwnerDiagnostic
                    )
                }
                #endif
                Spacer()
                if let observedAt = snapshot.observedAt {
                    Text(observedAt, style: .relative)
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.tertiaryText)
                }
            }
        }
        .padding(PopoverVisualStyle.cardPadding)
        .popoverSurface()
    }

    private var networkFacts: some View {
        VStack(spacing: PopoverVisualStyle.blockSpacing) {
            HStack(spacing: PopoverVisualStyle.Spacing.md) {
                PopoverFactTile(
                    title: "当前物理出口",
                    icon: "arrow.triangle.branch",
                    value: statusPresentation.outletText
                )
                PopoverFactTile(
                    title: "Wi-Fi",
                    icon: "wifi",
                    value: NetworkIdentityFormatter.wifiText(
                        ssid: networkInfoProvider.wifiSSID,
                        hideWiFiName: appConfig.hideWiFiName
                    )
                )
            }
            HStack(spacing: PopoverVisualStyle.Spacing.md) {
                PopoverFactTile(
                    title: "局域网地址",
                    icon: "pc",
                    value: networkInfoProvider.localIP,
                    monospacedValue: true
                )
                PopoverFactTile(
                    title: "DNS",
                    icon: "server.rack",
                    value: statusPresentation.dnsText,
                    state: dnsFacts == nil ? .unknown : (statusPresentation.monitoringNeedsAttention ? .warning : .ok)
                )
            }
        }
    }
}
