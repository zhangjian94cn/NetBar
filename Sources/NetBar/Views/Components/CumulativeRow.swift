import SwiftUI
import Cocoa

/// 累计流量行（带图标）
struct CumulativeRow: View {
    let app: ProcessTrafficMonitor.AppTraffic
    @ObservedObject var iconResolver: AppIconResolver

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
