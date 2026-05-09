import SwiftUI

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
