import SwiftUI

/// 代理状态标签 — 只负责领域配色，胶囊渲染交给 `PopoverBadge`。
struct ProxyBadge: View {
    let status: ProcessTrafficMonitor.AppProxyStatus

    var body: some View {
        PopoverBadge(text: status.label, color: color)
    }

    private var color: Color {
        switch status {
        case .direct: return PopoverVisualStyle.healthy
        case .proxied: return PopoverVisualStyle.accent
        case .mixed: return PopoverVisualStyle.warning
        case .unknown: return PopoverVisualStyle.tertiaryText
        }
    }
}
