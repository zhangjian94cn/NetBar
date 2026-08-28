import SwiftUI
import Cocoa

private enum TrafficTableLayout {
    static let columnSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 3
    static let rowHorizontalPadding: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 2
    static let visibleRowCount = 5
    static let rowHeight: CGFloat = 30
    static let iconSize: CGFloat = 20
    static let iconTextGap: CGFloat = 6
    static let routeWidth: CGFloat = 42
    static let trafficWidth: CGFloat = 76
    static let rowCornerRadius: CGFloat = 6

    static var bodyHeight: CGFloat {
        rowHeight * CGFloat(visibleRowCount) + rowSpacing * CGFloat(visibleRowCount - 1)
    }
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
struct TrafficTable<Rows: View>: View {
    let isEmpty: Bool
    let emptyText: String
    let emptyDetail: String?
    let bodyHeight: CGFloat
    private let rows: Rows

    init(
        isEmpty: Bool,
        emptyText: String,
        emptyDetail: String? = nil,
        bodyHeight: CGFloat = TrafficTableLayout.bodyHeight,
        @ViewBuilder rows: () -> Rows
    ) {
        self.isEmpty = isEmpty
        self.emptyText = emptyText
        self.emptyDetail = emptyDetail
        self.bodyHeight = bodyHeight
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: TrafficTableLayout.rowSpacing) {
            TrafficTableHeader()

            ZStack {
                if isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(emptyText)
                            .font(PopoverVisualStyle.Typography.bodyStrong)
                            .foregroundColor(PopoverVisualStyle.primaryText)
                        if let emptyDetail {
                            Text(emptyDetail)
                                .font(PopoverVisualStyle.Typography.caption)
                                .foregroundColor(PopoverVisualStyle.secondaryText)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 220)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .popoverGroup()
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: TrafficTableLayout.rowSpacing) {
                            rows
                        }
                    }
                }
            }
            .frame(height: bodyHeight)
        }
    }
}

/// Shared row layout for realtime and cumulative traffic tables.
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
                    .font(PopoverVisualStyle.Typography.bodyStrong)
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
        .padding(.vertical, TrafficTableLayout.rowVerticalPadding)
        .frame(height: TrafficTableLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: TrafficTableLayout.rowCornerRadius)
                .fill(Color.primary.opacity(0.025))
        )
    }
}
