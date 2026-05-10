import SwiftUI
import Cocoa

/// 累计流量行
struct CumulativeRow: View {
    let app: ProcessTrafficMonitor.AppTraffic
    @ObservedObject var iconResolver: AppIconResolver

    var body: some View {
        TrafficTableRow(
            app: app,
            iconResolver: iconResolver,
            downloadText: app.formattedCumulativeDown,
            uploadText: app.formattedCumulativeUp
        )
    }
}
