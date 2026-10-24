import SwiftUI

struct ApplicationTrafficQuery {
    enum Sort: String, CaseIterable { case download = "下载", upload = "上传", total = "总量" }
    static func rows(_ rows: [ProcessTrafficMonitor.AppTraffic], search: String, route: String, sort: Sort, cumulative: Bool) -> [ProcessTrafficMonitor.AppTraffic] {
        rows.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && (route == "全部路由" || $0.proxyStatus.label == route) }
            .sorted { a, b in
                func value(_ app: ProcessTrafficMonitor.AppTraffic) -> Double {
                    if cumulative {
                        switch sort { case .download: return Double(app.cumulativeDownload); case .upload: return Double(app.cumulativeUpload); case .total: return Double(app.totalCumulative) }
                    }
                    switch sort { case .download: return app.downloadSpeed; case .upload: return app.uploadSpeed; case .total: return app.totalSpeed }
                }
                return value(a) == value(b) ? a.id < b.id : value(a) > value(b)
            }
    }
}

extension Notification.Name { static let netbarFind = Notification.Name("NetBar.Find") }
