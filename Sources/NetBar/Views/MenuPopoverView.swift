import SwiftUI
import Cocoa

/// 代理状态标签
struct ProxyBadge: View {
    let status: ProcessTrafficMonitor.AppProxyStatus

    var color: Color {
        switch status {
        case .direct: return .green
        case .proxied: return .orange
        case .mixed: return .purple
        case .unknown: return .gray
        }
    }

    var body: some View {
        Text(status.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
    }
}

/// 菜单栏弹出详细面板
struct MenuPopoverView: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject var proxyDetector: ProxyDetector
    @ObservedObject var processTrafficMonitor: ProcessTrafficMonitor
    @ObservedObject var networkInfoProvider: NetworkInfoProvider
    var appIconResolver: AppIconResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- 标题栏 + 网络信息 ---
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

            Divider().padding(.horizontal, 12)

            // --- 实时总速度 ---
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

            Divider().padding(.horizontal, 12)

            // --- 实时活跃应用（固定高度，滚动查看）---
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
                        VStack(spacing: 3) {
                            ForEach(processTrafficMonitor.appSpeeds) { app in
                                AppSpeedRow(app: app, iconResolver: appIconResolver)
                            }
                        }
                    }
                    .frame(height: 120)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 12)

            // --- 累计流量排行 ---
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("📊 累计流量")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Picker("", selection: $processTrafficMonitor.selectedPeriod) {
                        ForEach(ProcessTrafficMonitor.TimePeriod.allCases, id: \.self) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                    .scaleEffect(0.85)
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
                        VStack(spacing: 3) {
                            ForEach(processTrafficMonitor.cumulativeRanking) { app in
                                CumulativeRow(app: app, iconResolver: appIconResolver)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 12)

            // --- 底部 ---
            HStack {
                Button(action: {
                    proxyDetector.checkProxySettings()
                    networkInfoProvider.refresh()
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
        .frame(width: 380)
    }
}

// MARK: - 子视图

/// 实时速度行（带图标）
struct AppSpeedRow: View {
    let app: ProcessTrafficMonitor.AppTraffic
    let iconResolver: AppIconResolver

    var body: some View {
        HStack(spacing: 6) {
            // 应用图标
            Image(nsImage: iconResolver.icon(for: app.name))
                .resizable()
                .frame(width: 16, height: 16)

            ProxyBadge(status: app.proxyStatus)

            Text(app.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Text("↑").font(.system(size: 8)).foregroundColor(.green)
                Text(app.formattedUpload)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(width: 80, alignment: .trailing)

            HStack(spacing: 2) {
                Text("↓").font(.system(size: 8)).foregroundColor(.blue)
                Text(app.formattedDownload)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.03)))
    }
}

/// 累计流量行（带图标）
struct CumulativeRow: View {
    let app: ProcessTrafficMonitor.AppTraffic
    let iconResolver: AppIconResolver

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: iconResolver.icon(for: app.name))
                .resizable()
                .frame(width: 14, height: 14)

            Text(app.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            ProxyBadge(status: app.proxyStatus)
                .frame(width: 36)

            Text(app.formattedCumulativeDown)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 65, alignment: .trailing)

            Text(app.formattedCumulativeUp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.02)))
    }
}
