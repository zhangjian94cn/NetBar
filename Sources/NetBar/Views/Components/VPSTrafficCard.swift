import SwiftUI

/// VPS 流量卡片
struct VPSTrafficCard: View {
    let vps: VPSTrafficMonitor.VPSTraffic

    var body: some View {
        PopoverCard(icon: "cloud.fill", title: vps.name) {
            Text(vps.hasData ? (vps.error == nil ? vps.lastUpdatedText : "上次成功：" + vps.lastUpdatedText + " · 数据已过期") : "尚未连接成功")
                .font(PopoverVisualStyle.Typography.caption)
                .foregroundColor(PopoverVisualStyle.tertiaryText)
        } content: {
            VStack(alignment: .leading, spacing: PopoverVisualStyle.Spacing.sm) {
                if vps.hasData {
                HStack(alignment: .top, spacing: PopoverVisualStyle.Spacing.lg) {
                    metric(title: "上传", icon: "arrow.up", value: vps.formattedUpload)
                    metric(title: "下载", icon: "arrow.down", value: vps.formattedDownload)
                    metric(title: "总计", icon: nil, value: vps.formattedTotal, suffix: "/ \(vps.formattedLimit)")
                    Spacer(minLength: 0)
                }

                if vps.quotaKnown, let fraction = PopoverMeter.fraction(vps.total, of: vps.totalLimit) {
                    PopoverMeter(fraction: fraction, tint: quotaTint(fraction))
                }

                } else {
                    Text("尚未取得数据").font(.system(size: 12)).foregroundColor(.secondary)
                }

                if let error = vps.error {
                    PopoverBanner(message: error, lineLimit: 2)
                }

                if !vps.clients.isEmpty {
                    Divider()
                    ForEach(vps.clients) { client in
                        HStack(spacing: PopoverVisualStyle.Spacing.sm) {
                            PopoverStatusDot(state: client.isOnline ? .ok : .unknown, diameter: 6)
                            Text(client.email)
                                .font(PopoverVisualStyle.Typography.captionStrong)
                                .foregroundColor(PopoverVisualStyle.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: PopoverVisualStyle.Spacing.xs)
                            Text("\(Formatters.formatBytes(client.upload)) ↑")
                                .font(PopoverVisualStyle.Typography.data)
                                .foregroundColor(PopoverVisualStyle.secondaryText)
                            Text("\(Formatters.formatBytes(client.download)) ↓")
                                .font(PopoverVisualStyle.Typography.data)
                                .foregroundColor(PopoverVisualStyle.secondaryText)
                        }
                    }
                }
            }
        }
    }

    /// Quota nearing its limit is a real warning, so the bar escalates instead
    /// of staying a decorative accent.
    private func quotaTint(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return PopoverVisualStyle.fault }
        if fraction >= 0.75 { return PopoverVisualStyle.warning }
        return PopoverVisualStyle.meterFill
    }

    private func metric(title: String, icon: String?, value: String, suffix: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                }
                Text(title)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.secondaryText)
            }
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(PopoverVisualStyle.primaryText)
                if let suffix {
                    Text(suffix)
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.tertiaryText)
                }
            }
        }
    }
}
