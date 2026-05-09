import SwiftUI
import Cocoa

/// 菜单栏弹出详细面板（容器视图）
/// 子视图已拆分到 Views/Components/ 目录
struct MenuPopoverView: View {
    private let maxVisibleActiveApps = 30
    private let maxVisibleRankingApps = 60

    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject var proxyDetector: ProxyDetector
    @ObservedObject var processTrafficMonitor: ProcessTrafficMonitor
    @ObservedObject var networkInfoProvider: NetworkInfoProvider
    @ObservedObject var vpsTrafficMonitor: VPSTrafficMonitor
    @ObservedObject var appIconResolver: AppIconResolver
    let contentHeight: CGFloat

    private var visibleIconNames: [String] {
        let names = processTrafficMonitor.appSpeeds.prefix(maxVisibleActiveApps).map(\.name) +
            processTrafficMonitor.cumulativeRanking.prefix(maxVisibleRankingApps).map(\.name)
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().padding(.horizontal, 12)
                speedSection
                Divider().padding(.horizontal, 12)
                activeAppsSection
                Divider().padding(.horizontal, 12)
                cumulativeSection
                vpsSection
                Divider().padding(.horizontal, 12)
                footerSection
            }
            .frame(width: 380)
        }
        .frame(width: 380, height: contentHeight)
        .onAppear {
            preloadVisibleIcons()
        }
        .onChange(of: visibleIconNames) { _ in
            preloadVisibleIcons()
        }
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
                Text(proxyDetector.status.isProxied ? "系统代理已开启" : "系统直连")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(proxyDetector.status.isProxied ? .orange : .green)
            }

            // Wi-Fi + IP 信息
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(networkInfoProvider.wifiSSID)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "pc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(networkInfoProvider.localIP)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 实时总速度

    private var speedSection: some View {
        HStack(spacing: 20) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 13))
                    Text("下载")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(networkMonitor.currentSpeed.formattedDownload)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 35)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 13))
                    Text("上传")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(networkMonitor.currentSpeed.formattedUpload)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 实时活跃应用

    private var activeAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("⚡ 实时活跃")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(processTrafficMonitor.appSpeeds.count) 个")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 2)

            if processTrafficMonitor.appSpeeds.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无活跃应用")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(height: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(processTrafficMonitor.appSpeeds.prefix(maxVisibleActiveApps)) { app in
                            AppSpeedRow(app: app, iconResolver: appIconResolver)
                        }
                    }
                }
                .frame(height: 120)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 累计流量排行

    private var cumulativeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("📊 累计流量")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                TimePeriodPopUpButton(selection: $processTrafficMonitor.selectedPeriod)
                    .frame(width: 94, height: 22)
            }
            .padding(.bottom, 2)

            if processTrafficMonitor.cumulativeRanking.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无流量记录")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 4) {
                    Text("应用")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 20) // icon space
                    Text("路由")
                        .frame(width: 36)
                    Text("↓ 下载")
                        .frame(width: 65, alignment: .trailing)
                    Text("↑ 上传")
                        .frame(width: 65, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(processTrafficMonitor.cumulativeRanking.prefix(maxVisibleRankingApps)) { app in
                            CumulativeRow(app: app, iconResolver: appIconResolver)
                        }
                    }
                }
                .frame(height: 120)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                vpsTrafficMonitor.refresh()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("刷新")
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
                    Text("退出")
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
}
