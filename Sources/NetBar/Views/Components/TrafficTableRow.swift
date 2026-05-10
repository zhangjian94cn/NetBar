import SwiftUI
import Cocoa

private enum TrafficTableLayout {
    static let columnSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 3
    static let rowHorizontalPadding: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 2
    static let visibleRowCount = 5
    static let rowHeight: CGFloat = 22
    static let iconSize: CGFloat = 16
    static let iconTextGap: CGFloat = 6
    static let routeWidth: CGFloat = 42
    static let trafficWidth: CGFloat = 76
    static let rowCornerRadius: CGFloat = 4

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
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, TrafficTableLayout.rowHorizontalPadding)
    }
}

/// Shared scrollable table shell for realtime and cumulative traffic tables.
struct TrafficTable<Rows: View>: View {
    let isEmpty: Bool
    let emptyText: String
    private let rows: Rows

    init(isEmpty: Bool, emptyText: String, @ViewBuilder rows: () -> Rows) {
        self.isEmpty = isEmpty
        self.emptyText = emptyText
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: TrafficTableLayout.rowSpacing) {
            TrafficTableHeader()

            ZStack {
                if isEmpty {
                    Text(emptyText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: TrafficTableLayout.rowSpacing) {
                            rows
                        }
                    }
                }
            }
            .frame(height: TrafficTableLayout.bodyHeight)
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
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProxyBadge(status: app.proxyStatus)
                .frame(width: TrafficTableLayout.routeWidth)

            Text(downloadText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: TrafficTableLayout.trafficWidth, alignment: .trailing)

            Text(uploadText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
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
