import SwiftUI
import Cocoa

private enum TrafficTableLayout {
    static let columnSpacing = PopoverVisualStyle.Spacing.xs
    static let rowHorizontalPadding = PopoverVisualStyle.Spacing.sm
    static let rowHeight: CGFloat = 30
    static let iconSize: CGFloat = 20
    static let iconTextGap: CGFloat = 8
    static let routeWidth: CGFloat = 48
    static let trafficWidth: CGFloat = 72
}

/// Shared header for realtime and cumulative traffic tables.
struct TrafficTableHeader: View {
    var body: some View {
        HStack(spacing: TrafficTableLayout.columnSpacing) {
            Text(L10n.Table.app)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TrafficTableLayout.iconSize + TrafficTableLayout.iconTextGap)

            Text(L10n.Table.route)
                .frame(width: TrafficTableLayout.routeWidth)

            Text(L10n.Table.downloadHeader)
                .frame(width: TrafficTableLayout.trafficWidth, alignment: .trailing)

            Text(L10n.Table.uploadHeader)
                .frame(width: TrafficTableLayout.trafficWidth, alignment: .trailing)
        }
        .font(PopoverVisualStyle.Typography.captionStrong)
        .foregroundColor(PopoverVisualStyle.secondaryText)
        .padding(.horizontal, TrafficTableLayout.rowHorizontalPadding)
    }
}

/// Shared scrollable table shell for realtime and cumulative traffic tables.
///
/// The body claims the remaining panel height instead of a hard-coded one, so
/// the applications page fills the fixed frame rather than leaving dead space
/// under the last row.
struct TrafficTable<Rows: View>: View {
    let isEmpty: Bool
    let emptyText: String
    let emptyDetail: String?
    private let rows: Rows

    init(
        isEmpty: Bool,
        emptyText: String,
        emptyDetail: String? = nil,
        @ViewBuilder rows: () -> Rows
    ) {
        self.isEmpty = isEmpty
        self.emptyText = emptyText
        self.emptyDetail = emptyDetail
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: PopoverVisualStyle.Spacing.xs) {
            TrafficTableHeader()

            ZStack {
                if isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            rows
                        }
                        .padding(.vertical, PopoverVisualStyle.Spacing.xs)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .popoverSurface()
        }
    }

    private var emptyState: some View {
        VStack(spacing: PopoverVisualStyle.Spacing.sm) {
            Image(systemName: "app.dashed")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(PopoverVisualStyle.tertiaryText)
            Text(emptyText)
                .font(PopoverVisualStyle.Typography.bodyStrong)
                .foregroundColor(PopoverVisualStyle.secondaryText)
            if let emptyDetail {
                Text(emptyDetail)
                    .font(PopoverVisualStyle.Typography.caption)
                    .foregroundColor(PopoverVisualStyle.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared row layout for realtime and cumulative traffic tables.
///
/// Rows are plain: the table body already provides one surface, so per-row
/// pills would stack grey on grey.
struct TrafficTableRow: View {
    let app: ProcessTrafficMonitor.AppTraffic
    @ObservedObject var iconResolver: AppIconResolver
    let downloadText: String
    let uploadText: String

    var body: some View {
        HStack(spacing: TrafficTableLayout.columnSpacing) {
            HStack(spacing: TrafficTableLayout.iconTextGap) {
                Image(nsImage: iconResolver.icon(for: app.name))
                    .resizable()
                    .frame(width: TrafficTableLayout.iconSize, height: TrafficTableLayout.iconSize)

                Text(app.name)
                    .font(PopoverVisualStyle.Typography.body)
                    .foregroundColor(PopoverVisualStyle.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProxyBadge(status: app.proxyStatus)
                .frame(width: TrafficTableLayout.routeWidth)

            Text(downloadText)
                .font(PopoverVisualStyle.Typography.data)
                .foregroundColor(PopoverVisualStyle.secondaryText)
                .frame(width: TrafficTableLayout.trafficWidth, alignment: .trailing)

            Text(uploadText)
                .font(PopoverVisualStyle.Typography.data)
                .foregroundColor(PopoverVisualStyle.secondaryText)
                .frame(width: TrafficTableLayout.trafficWidth, alignment: .trailing)
        }
        .padding(.horizontal, TrafficTableLayout.rowHorizontalPadding)
        .frame(height: TrafficTableLayout.rowHeight)
    }
}
