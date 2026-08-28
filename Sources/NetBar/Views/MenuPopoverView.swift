import SwiftUI
import Cocoa

/// 菜单栏弹出详细面板（容器视图）
/// 子视图已拆分到 Views/Components/ 目录
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

    @State private var selectedTab: Int = 0

    private var visibleIconNames: [String] {
        guard DistributionFlavor.current.supportsProcessTraffic else {
            return []
        }
        let names = processTrafficMonitor.appSpeeds.prefix(maxTableApps).map(\.name) +
            processTrafficMonitor.cumulativeRanking.prefix(maxTableApps).map(\.name)
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection

            if DistributionFlavor.current.supportsNetworkModeSwitch {
                Divider().padding(.horizontal, 12)
                NetworkControlTabs(
                    networkController: networkModeController,
                    overlayController: clashOverlayModeController
                )
            }

            Divider().padding(.horizontal, 12)
            egressIPSection
            Divider().padding(.horizontal, 12)
            speedSection
            Divider().padding(.horizontal, 12)

            if DistributionFlavor.current.supportsProcessTraffic {
                tabSelector
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                if selectedTab == 0 {
                    activeAppsSection
                } else {
                    cumulativeSection
                }
            }

            vpsSection
            
            Divider().padding(.horizontal, 12)
            footerSection
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            preloadVisibleIcons()
            if DistributionFlavor.current.supportsNetworkModeSwitch {
                networkModeController.beginObserving()
                clashOverlayModeController.refresh()
            }
        }
        .onDisappear {
            networkModeController.endObserving()
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

    // MARK: - Tab 切换

    private var tabSelector: some View {
        HStack(spacing: 0) {
            tabButton(title: L10n.Tab.realtime, systemImage: "bolt.fill", tag: 0, iconColor: .orange)
            tabButton(title: L10n.Tab.cumulative, systemImage: "chart.bar.fill", tag: 1, iconColor: .blue)
        }
        .padding(2)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func tabButton(title: String, systemImage: String, tag: Int, iconColor: Color) -> some View {
        let isSelected = selectedTab == tag

        return Button {
            selectedTab = tag
            if tag == 1 {
                processTrafficMonitor.requestCumulativeRefresh()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(1)
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.18) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 标题栏 + 网络信息

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("NetBar")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(proxyDetector.status.headerText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(proxyStatusColor)
            }

            // Wi-Fi + IP 信息
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(NetworkIdentityFormatter.wifiText(
                        ssid: networkInfoProvider.wifiSSID,
                        hideWiFiName: appConfig.hideWiFiName
                    ))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .help("Wi-Fi 名称可能被隐私设置隐藏，不影响代理或公网出口 IP 判断。")

                HStack(spacing: 4) {
                    Image(systemName: "pc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(NetworkIdentityFormatter.lanText(ip: networkInfoProvider.localIP))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .help("这是本机局域网地址，不是代理后的公网出口 IP。")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var proxyStatusColor: Color {
        if proxyDetector.status.isSystemProxyEnabled {
            return .orange
        }
        if proxyDetector.status.isVPNActive {
            return .blue
        }
        return .green
    }

    // MARK: - 实时总速度

    private var speedSection: some View {
        HStack(spacing: 20) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 13))
                    Text(L10n.Speed.download)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(networkMonitor.currentSpeed.formattedDownload)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .accessibilityLabel("下载速度")
                    .accessibilityValue(networkMonitor.currentSpeed.formattedDownload)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 35)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 13))
                    Text(L10n.Speed.upload)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(networkMonitor.currentSpeed.formattedUpload)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .accessibilityLabel("上传速度")
                    .accessibilityValue(networkMonitor.currentSpeed.formattedUpload)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 实时活跃应用

    private var activeAppsSection: some View {
        TrafficTable(isEmpty: processTrafficMonitor.appSpeeds.isEmpty, emptyText: L10n.Table.noActiveApps) {
            ForEach(Array(processTrafficMonitor.appSpeeds.prefix(maxTableApps))) { app in
                AppSpeedRow(app: app, iconResolver: appIconResolver)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 累计流量排行

    private var cumulativeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                TimePeriodPopUpButton(selection: $processTrafficMonitor.selectedPeriod)
                    .frame(width: 94, height: 22)
            }
            .padding(.bottom, 2)

            TrafficTable(isEmpty: processTrafficMonitor.cumulativeRanking.isEmpty, emptyText: L10n.Table.noTrafficRecords) {
                ForEach(Array(processTrafficMonitor.cumulativeRanking.prefix(maxTableApps))) { app in
                    CumulativeRow(app: app, iconResolver: appIconResolver)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - VPS 流量

    @ViewBuilder
    private var vpsSection: some View {
        if !vpsTrafficMonitor.vpsList.isEmpty {
            Divider().padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(vpsTrafficMonitor.vpsList) { vps in
                    VPSTrafficCard(vps: vps)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 底部

    private var footerSection: some View {
        HStack {
            Button(action: {
                proxyDetector.checkProxySettings()
                networkInfoProvider.refresh()
                egressIPMonitor.refresh(force: true)
                vpsTrafficMonitor.refresh()
                if DistributionFlavor.current.supportsProcessTraffic {
                    processTrafficMonitor.requestCumulativeRefresh()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text(L10n.Footer.refresh)
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                SettingsWindowController.shared.show(coordinator: coordinator)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.system(size: 10))
                    Text(L10n.Footer.settings)
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                    Text(L10n.Footer.quit)
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func preloadVisibleIcons() {
        appIconResolver.preloadIcons(for: visibleIconNames)
    }

    @ViewBuilder
    private var egressIPSection: some View {
        if appConfig.ipCheckEnabled {
            EgressIPCard(monitor: egressIPMonitor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}
