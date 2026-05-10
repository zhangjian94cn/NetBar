import SwiftUI
import Cocoa

/// 实时速度行
struct AppSpeedRow: View {
    let app: ProcessTrafficMonitor.AppTraffic
    @ObservedObject var iconResolver: AppIconResolver

    var body: some View {
        TrafficTableRow(
            app: app,
            iconResolver: iconResolver,
            downloadText: app.formattedDownload,
            uploadText: app.formattedUpload
        )
    }
}
