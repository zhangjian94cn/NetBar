import Foundation

/// 持久化流量存储器 — 将每个应用的流量数据写入磁盘，支持长期统计
class TrafficStore: MonitorProtocol {

    /// 采样增量，批量写入时用来减少队列切换
    struct TrafficIncrement {
        let appName: String
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

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

        var formattedIn: String { Formatters.formatBytes(totalIn) }
        var formattedOut: String { Formatters.formatBytes(totalOut) }
        var formattedTotal: String { Formatters.formatBytes(total) }
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
    private var recordsByDateCache: [String: [HourlyRecord]] = [:]
    private var flushTimer: Timer?
    private let queue = DispatchQueue(label: "com.zjah.NetBar.trafficStore")

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
        queue.async {
            let hourKey = self.hourFormatter.string(from: Date())
            self.recordOnQueue(appName: appName, bytesIn: bytesIn, bytesOut: bytesOut, hourKey: hourKey)
        }
    }

    func recordBatch(_ increments: [TrafficIncrement]) {
        let validIncrements = increments.filter { $0.bytesIn > 0 || $0.bytesOut > 0 }
        guard !validIncrements.isEmpty else { return }

        queue.async {
            let hourKey = self.hourFormatter.string(from: Date())
            for increment in validIncrements {
                self.recordOnQueue(
                    appName: increment.appName,
                    bytesIn: increment.bytesIn,
                    bytesOut: increment.bytesOut,
                    hourKey: hourKey
                )
            }
        }
    }

    private func recordOnQueue(appName: String, bytesIn: UInt64, bytesOut: UInt64, hourKey: String) {
        // 如果跨小时了，先刷盘旧数据
        if hourKey != currentHourKey {
            flushToDiskOnQueue()
            currentHourKey = hourKey
        }

        if let existing = hourBuffer[appName] {
            hourBuffer[appName] = (existing.bytesIn + bytesIn, existing.bytesOut + bytesOut)
        } else {
            hourBuffer[appName] = (bytesIn, bytesOut)
        }
    }

    func start() {
        startPeriodicFlush()
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
        flushTimer?.invalidate()
        flushTimer = nil
        queue.sync {
            flushToDiskOnQueue()
        }
    }

    /// 将内存缓冲写入磁盘（按日期分文件）
    func flushToDisk() {
        queue.async {
            self.flushToDiskOnQueue()
        }
    }

    private func flushToDiskOnQueue() {
        guard !hourBuffer.isEmpty else { return }

        let dateKey = String(currentHourKey.prefix(10))  // "2026-03-21"
        let fileURL = fileURL(for: dateKey)
        var records = cachedRecords(for: dateKey)

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

        recordsByDateCache[dateKey] = records

        // 写回文件
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.storage.error("流量数据写入失败: \(fileURL.path) — \(error.localizedDescription)")
        }

        hourBuffer.removeAll()
    }

    // MARK: - 读取

    /// 查询指定时间范围内的 App 流量汇总
    func query(from startDate: Date, to endDate: Date = Date()) -> [AppSummary] {
        queue.sync {
            queryOnQueue(from: startDate, to: endDate)
        }
    }

    private func queryOnQueue(from startDate: Date, to endDate: Date = Date()) -> [AppSummary] {
        var summaries: [String: AppSummary] = [:]
        let startHourKey = hourFormatter.string(from: startDate)
        let endHourKey = hourFormatter.string(from: endDate)

        func addSummary(appName: String, bytesIn: UInt64, bytesOut: UInt64) {
            if var summary = summaries[appName] {
                summary.totalIn += bytesIn
                summary.totalOut += bytesOut
                summaries[appName] = summary
            } else {
                summaries[appName] = AppSummary(
                    appName: appName,
                    totalIn: bytesIn,
                    totalOut: bytesOut
                )
            }
        }

        // 遍历日期范围内的所有文件
        var date = Calendar.current.startOfDay(for: startDate)
        let endDay = Calendar.current.startOfDay(for: endDate)

        while date <= endDay {
            let dateKey = dateFormatter.string(from: date)
            let records = cachedRecords(for: dateKey)

            for record in records {
                if record.hour >= startHourKey && record.hour <= endHourKey {
                    addSummary(appName: record.appName, bytesIn: record.bytesIn, bytesOut: record.bytesOut)
                }
            }

            date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        }

        // 合并当前内存缓冲
        if currentHourKey >= startHourKey && currentHourKey <= endHourKey {
            for (appName, data) in hourBuffer {
                addSummary(appName: appName, bytesIn: data.bytesIn, bytesOut: data.bytesOut)
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
            Log.storage.error("流量数据读取失败: \(fileURL.path) — \(error.localizedDescription)")
            return []
        }
    }

    private func fileURL(for dateKey: String) -> URL {
        storageDir.appendingPathComponent("traffic-\(dateKey).json")
    }

    private func cachedRecords(for dateKey: String) -> [HourlyRecord] {
        if let cached = recordsByDateCache[dateKey] {
            return cached
        }

        let records = loadRecords(from: fileURL(for: dateKey))
        recordsByDateCache[dateKey] = records
        return records
    }
}
