import Foundation

/// 持久化流量存储器 — 将每个应用的流量数据写入磁盘，支持长期统计
class TrafficStore {

    /// 每小时汇总的流量记录（持久化单位）
    struct HourlyRecord: Codable {
        let hour: String          // "2026-03-21T14" 格式
        let appName: String
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    /// 查询用的汇总结果
    struct AppSummary {
        let appName: String
        var totalIn: UInt64
        var totalOut: UInt64
        var total: UInt64 { totalIn + totalOut }

        var formattedIn: String { formatBytes(totalIn) }
        var formattedOut: String { formatBytes(totalOut) }
        var formattedTotal: String { formatBytes(total) }

        private func formatBytes(_ bytes: UInt64) -> String {
            let b = Double(bytes)
            if b < 1024 { return String(format: "%.0f B", b) }
            else if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
            else if b < 1024 * 1024 * 1024 { return String(format: "%.2f MB", b / (1024 * 1024)) }
            else { return String(format: "%.2f GB", b / (1024 * 1024 * 1024)) }
        }
    }

    private let storageDir: URL
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH"
        return f
    }()

    // 内存中当前小时的缓冲
    private var currentHourKey: String = ""
    private var hourBuffer: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var flushTimer: Timer?

    init() {
        // 存储在 ~/Library/Application Support/NetBar/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDir = appSupport.appendingPathComponent("NetBar", isDirectory: true)

        // 创建目录
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        currentHourKey = hourFormatter.string(from: Date())
    }

    // MARK: - 写入

    /// 记录一批流量增量（由 ProcessTrafficMonitor 调用）
    func record(appName: String, bytesIn: UInt64, bytesOut: UInt64) {
        guard bytesIn > 0 || bytesOut > 0 else { return }

        let now = Date()
        let hourKey = hourFormatter.string(from: now)

        // 如果跨小时了，先刷盘旧数据
        if hourKey != currentHourKey {
            flushToDisk()
            currentHourKey = hourKey
        }

        if let existing = hourBuffer[appName] {
            hourBuffer[appName] = (existing.bytesIn + bytesIn, existing.bytesOut + bytesOut)
        } else {
            hourBuffer[appName] = (bytesIn, bytesOut)
        }
    }

    /// 启动定时刷盘（每 30 秒）
    func startPeriodicFlush() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.flushToDisk()
        }
        if let timer = flushTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        flushToDisk()
        flushTimer?.invalidate()
        flushTimer = nil
    }

    /// 将内存缓冲写入磁盘（按日期分文件）
    func flushToDisk() {
        guard !hourBuffer.isEmpty else { return }

        let dateKey = String(currentHourKey.prefix(10))  // "2026-03-21"
        let fileURL = storageDir.appendingPathComponent("traffic-\(dateKey).json")

        // 读取已有数据
        var records = loadRecords(from: fileURL)

        // 合并缓冲
        for (appName, data) in hourBuffer {
            if let idx = records.firstIndex(where: { $0.hour == currentHourKey && $0.appName == appName }) {
                records[idx].bytesIn += data.bytesIn
                records[idx].bytesOut += data.bytesOut
            } else {
                records.append(HourlyRecord(
                    hour: currentHourKey,
                    appName: appName,
                    bytesIn: data.bytesIn,
                    bytesOut: data.bytesOut
                ))
            }
        }

        // 写回文件
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("TrafficStore: 写入失败 \(error)")
        }

        hourBuffer.removeAll()
    }

    // MARK: - 读取

    /// 查询指定时间范围内的 App 流量汇总
    func query(from startDate: Date, to endDate: Date = Date()) -> [AppSummary] {
        var allRecords: [HourlyRecord] = []

        // 遍历日期范围内的所有文件
        var date = Calendar.current.startOfDay(for: startDate)
        let endDay = Calendar.current.startOfDay(for: endDate)

        while date <= endDay {
            let dateKey = dateFormatter.string(from: date)
            let fileURL = storageDir.appendingPathComponent("traffic-\(dateKey).json")
            let records = loadRecords(from: fileURL)

            let startHourKey = hourFormatter.string(from: startDate)
            let endHourKey = hourFormatter.string(from: endDate)

            for record in records {
                if record.hour >= startHourKey && record.hour <= endHourKey {
                    allRecords.append(record)
                }
            }

            date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        }

        // 合并当前内存缓冲
        let currentStartHour = hourFormatter.string(from: startDate)
        let currentEndHour = hourFormatter.string(from: endDate)
        if currentHourKey >= currentStartHour && currentHourKey <= currentEndHour {
            for (appName, data) in hourBuffer {
                allRecords.append(HourlyRecord(
                    hour: currentHourKey, appName: appName,
                    bytesIn: data.bytesIn, bytesOut: data.bytesOut
                ))
            }
        }

        // 汇总
        var summaries: [String: AppSummary] = [:]
        for record in allRecords {
            if var s = summaries[record.appName] {
                s.totalIn += record.bytesIn
                s.totalOut += record.bytesOut
                summaries[record.appName] = s
            } else {
                summaries[record.appName] = AppSummary(
                    appName: record.appName,
                    totalIn: record.bytesIn,
                    totalOut: record.bytesOut
                )
            }
        }

        return summaries.values.sorted { $0.total > $1.total }
    }

    /// 快捷查询：今天
    func queryToday() -> [AppSummary] {
        let start = Calendar.current.startOfDay(for: Date())
        return query(from: start)
    }

    /// 快捷查询：本月
    func queryThisMonth() -> [AppSummary] {
        let now = Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        let start = Calendar.current.date(from: comps)!
        return query(from: start)
    }

    /// 快捷查询：最近 N 天
    func queryLastDays(_ n: Int) -> [AppSummary] {
        let start = Calendar.current.date(byAdding: .day, value: -n, to: Date())!
        return query(from: start)
    }

    // MARK: - 私有方法

    private func loadRecords(from fileURL: URL) -> [HourlyRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([HourlyRecord].self, from: data)
        } catch {
            print("TrafficStore: 读取失败 \(error)")
            return []
        }
    }
}
