import SwiftUI

/// 代理状态标签
struct ProxyBadge: View {
    let status: ProcessTrafficMonitor.AppProxyStatus

    var color: Color {
        switch status {
        case .direct: return PopoverVisualStyle.healthy
        case .proxied: return PopoverVisualStyle.warning
        case .mixed: return .purple
        case .unknown: return PopoverVisualStyle.tertiaryText
        }
    }

    var body: some View {
        Text(status.label)
            .font(PopoverVisualStyle.Typography.captionStrong)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.11)))
    }
}
