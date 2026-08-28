import SwiftUI

/// VPS 流量卡片
struct VPSTrafficCard: View {
    let vps: VPSTrafficMonitor.VPSTraffic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(PopoverVisualStyle.vpsAccent)
                Text(vps.name)
                    .font(PopoverVisualStyle.Typography.section)
                
                Spacer()
                
                Text("⟳ \(vps.lastUpdatedText)")
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(PopoverVisualStyle.secondaryText)
                        Text("上传")
                            .font(PopoverVisualStyle.Typography.caption)
                            .foregroundColor(PopoverVisualStyle.secondaryText)
                    }
                    Text(vps.formattedUpload)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(PopoverVisualStyle.primaryText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.blue)
                        Text("下载")
                            .font(PopoverVisualStyle.Typography.caption)
                            .foregroundColor(PopoverVisualStyle.secondaryText)
                    }
                    Text(vps.formattedDownload)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(PopoverVisualStyle.primaryText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("总计")
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.secondaryText)
                    HStack(spacing: 3) {
                        Text(vps.formattedTotal)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(PopoverVisualStyle.primaryText)
                        Text("/ \(vps.formattedLimit)")
                            .font(PopoverVisualStyle.Typography.caption)
                            .foregroundColor(PopoverVisualStyle.secondaryText)
                    }
                }

                Spacer()
            }

            if let error = vps.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(PopoverVisualStyle.warning)
                    Text(error)
                        .font(PopoverVisualStyle.Typography.caption)
                        .foregroundColor(PopoverVisualStyle.warning)
                }
            }

            if !vps.clients.isEmpty {
                Divider()
                ForEach(vps.clients) { client in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(client.isOnline ? PopoverVisualStyle.healthy : PopoverVisualStyle.tertiaryText)
                            .frame(width: 6, height: 6)
                        Text(client.email)
                            .font(PopoverVisualStyle.Typography.captionStrong)
                            .foregroundColor(PopoverVisualStyle.primaryText)
                        Spacer()
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
        .padding(12)
        .popoverGroup(tint: PopoverVisualStyle.vpsAccent)
    }
}
