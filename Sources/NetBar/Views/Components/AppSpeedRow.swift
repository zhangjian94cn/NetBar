import SwiftUI
import Cocoa

/// 实时速度行（带图标）
struct AppSpeedRow: View {
    let app: ProcessTrafficMonitor.AppTraffic
    @ObservedObject var iconResolver: AppIconResolver

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
