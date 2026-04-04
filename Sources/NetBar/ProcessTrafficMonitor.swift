import Foundation

/// 按应用维度的流量监控器 — 通过长连接 nettop 流式解析
class ProcessTrafficMonitor: ObservableObject {

    /// 时间窗口选项
    enum TimePeriod: String, CaseIterable {
        case oneMinute = "1 分钟"
        case fiveMinutes = "5 分钟"
        case oneHour = "1 小时"
        case sinceStart = "启动至今"
        case today = "今天"
        case sevenDays = "7 天"
        case thirtyDays = "30 天"
        case thisMonth = "本月"

        var isLongTerm: Bool {
            switch self {
            case .today, .sevenDays, .thirtyDays, .thisMonth: return true
            default: return false
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .oneMinute: return 60
            case .fiveMinutes: return 300
            case .oneHour: return 3600
            case .sinceStart: return .infinity
            case .today: return .infinity
            case .sevenDays: return .infinity
            case .thirtyDays: return .infinity
            case .thisMonth: return .infinity
            }
        }
    }

    /// 每个应用的流量和代理状态
    struct AppTraffic: Identifiable {
        let id: String
        let name: String
        var downloadSpeed: Double
        var uploadSpeed: Double
        var cumulativeDownload: UInt64
        var cumulativeUpload: UInt64
        var proxyStatus: AppProxyStatus

        var totalSpeed: Double { downloadSpeed + uploadSpeed }
        var totalCumulative: UInt64 { cumulativeDownload + cumulativeUpload }

        var formattedDownload: String { formatSpeed(downloadSpeed) }
        var formattedUpload: String { formatSpeed(uploadSpeed) }
        var formattedCumulativeDown: String { formatBytes(cumulativeDownload) }
        var formattedCumulativeUp: String { formatBytes(cumulativeUpload) }
        var formattedCumulativeTotal: String { formatBytes(totalCumulative) }

        private func formatSpeed(_ bytesPerSec: Double) -> String {
            if bytesPerSec < 1024 {
                return String(format: "%.0f B/s", bytesPerSec)
            } else if bytesPerSec < 1024 * 1024 {
                return String(format: "%.1f KB/s", bytesPerSec / 1024)
            } else if bytesPerSec < 1024 * 1024 * 1024 {
                return String(format: "%.2f MB/s", bytesPerSec / (1024 * 1024))
            } else {
                return String(format: "%.2f GB/s", bytesPerSec / (1024 * 1024 * 1024))
            }
        }

        private func formatBytes(_ bytes: UInt64) -> String {
            let b = Double(bytes)
            if b < 1024 {
                return String(format: "%.0f B", b)
            } else if b < 1024 * 1024 {
                return String(format: "%.1f KB", b / 1024)
            } else if b < 1024 * 1024 * 1024 {
                return String(format: "%.2f MB", b / (1024 * 1024))
            } else {
                return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
            }
        }
    }

    enum AppProxyStatus {
        case direct
        case proxied
        case mixed
        case unknown

        var label: String {
            switch self {
            case .direct: return "直连"
            case .proxied: return "代理"
            case .mixed: return "混合"
            case .unknown: return "—"
            }
        }

        var colorName: String {
            switch self {
            case .direct: return "green"
            case .proxied: return "orange"
            case .mixed: return "purple"
            case .unknown: return "gray"
            }
        }
    }

    private struct TrafficRecord {
        let timestamp: Date
        let appName: String
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    @Published var appSpeeds: [AppTraffic] = []
    @Published var cumulativeRanking: [AppTraffic] = []
    @Published var selectedPeriod: TimePeriod = .fiveMinutes

    private let vpnPrefixes = ["utun", "ipsec", "ppp", "tap", "tun"]
    private let hiddenProcesses: Set<String> = [
        "launchd", "configd", "syslogd", "kdc", "airportd",
        "wifianalyticsd", "identityserviced", "rapportd",
        "sharingd", "ControlCenter", "wifivelocityd",
        "netbiosd", "wifip2pd", "mDNSResponder", "apsd",
        "identityservice", "trustd", "ARDAgent"
    ]

    private var previousStats: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var previousTime: Date = Date()
    private var trafficHistory: [TrafficRecord] = []
    private var appInterfaces: [String: Set<String>] = [:]
    private let startTime = Date()

    // 流式 nettop
    private var nettopProcess: Process?
    private var nettopPipe: Pipe?
    private var outputBuffer: String = ""
    private var timer: Timer?

    /// 持久化存储器
    var trafficStore: TrafficStore?

    init() {}

    func start(interval: TimeInterval = 2.0) {
        // 先获取一次基线数据（同步方式）
        let (stats, interfaces) = fetchNettopOnce()
        previousStats = stats
        previousTime = Date()
        appInterfaces = interfaces

        // 定期采样（仍然使用定时执行 nettop，但更轻量）
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.update()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        nettopProcess?.terminate()
        nettopProcess = nil
    }

    private func update() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let (currentStats, interfaces) = self.fetchNettopOnce()
            let now = Date()
            let elapsed = now.timeIntervalSince(self.previousTime)
            guard elapsed > 0.5 else { return }

            // 合并接口信息
            for (app, ifaces) in interfaces {
                if var existing = self.appInterfaces[app] {
                    existing.formUnion(ifaces)
                    self.appInterfaces[app] = existing
                } else {
                    self.appInterfaces[app] = ifaces
                }
            }

            var appCurrent: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
            var appPrevious: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]

            for (key, val) in currentStats {
                let n = self.extractAppName(from: key)
                if let e = appCurrent[n] { appCurrent[n] = (e.bytesIn + val.bytesIn, e.bytesOut + val.bytesOut) }
                else { appCurrent[n] = val }
            }
            for (key, val) in self.previousStats {
                let n = self.extractAppName(from: key)
                if let e = appPrevious[n] { appPrevious[n] = (e.bytesIn + val.bytesIn, e.bytesOut + val.bytesOut) }
                else { appPrevious[n] = val }
            }

            var speeds: [AppTraffic] = []
            for (appName, current) in appCurrent {
                guard !self.hiddenProcesses.contains(appName) else { continue }
                if let previous = appPrevious[appName] {
                    let dlBytes = current.bytesIn >= previous.bytesIn ? current.bytesIn - previous.bytesIn : 0
                    let ulBytes = current.bytesOut >= previous.bytesOut ? current.bytesOut - previous.bytesOut : 0
                    let dlSpeed = Double(dlBytes) / elapsed
                    let ulSpeed = Double(ulBytes) / elapsed

                    if dlBytes > 0 || ulBytes > 0 {
                        self.trafficHistory.append(TrafficRecord(
                            timestamp: now, appName: appName, bytesIn: dlBytes, bytesOut: ulBytes
                        ))
                        // 持久化到磁盘
                        self.trafficStore?.record(appName: appName, bytesIn: dlBytes, bytesOut: ulBytes)
                    }

                    if dlSpeed > 10 || ulSpeed > 10 {
                        speeds.append(AppTraffic(
                            id: appName, name: appName,
                            downloadSpeed: dlSpeed, uploadSpeed: ulSpeed,
                            cumulativeDownload: 0, cumulativeUpload: 0,
                            proxyStatus: self.determineProxyStatus(for: appName)
                        ))
                    }
                }
            }

            speeds.sort { $0.totalSpeed > $1.totalSpeed }
            let cutoff = now.addingTimeInterval(-3700)
            self.trafficHistory.removeAll { $0.timestamp < cutoff }
            let cumulative = self.computeCumulativeRanking(period: self.selectedPeriod, now: now)

            DispatchQueue.main.async {
                self.appSpeeds = speeds
                self.cumulativeRanking = cumulative
            }

            self.previousStats = currentStats
            self.previousTime = now
        }
    }

    private func determineProxyStatus(for appName: String) -> AppProxyStatus {
        guard let interfaces = appInterfaces[appName] else { return .unknown }
        let nonLoopback = interfaces.filter { $0 != "lo0" && !$0.isEmpty }
        guard !nonLoopback.isEmpty else { return .unknown }

        let hasVPN = nonLoopback.contains { iface in vpnPrefixes.contains { iface.hasPrefix($0) } }
        let hasDirect = nonLoopback.contains { iface in !vpnPrefixes.contains { iface.hasPrefix($0) } }

        if hasVPN && hasDirect { return .mixed }
        if hasVPN { return .proxied }
        if hasDirect { return .direct }
        return .unknown
    }

    private func computeCumulativeRanking(period: TimePeriod, now: Date) -> [AppTraffic] {
        // 长期查询走持久化存储（包括 sinceStart 超过 1 小时的情况）
        if let store = trafficStore, (period.isLongTerm || period == .sinceStart) {
            let summaries: [TrafficStore.AppSummary]
            switch period {
            case .today:
                summaries = store.queryToday()
            case .sevenDays:
                summaries = store.queryLastDays(7)
            case .thirtyDays:
                summaries = store.queryLastDays(30)
            case .thisMonth:
                summaries = store.queryThisMonth()
            case .sinceStart:
                summaries = store.query(from: startTime)
            default:
                summaries = []
            }
            return summaries.map { s in
                AppTraffic(
                    id: s.appName, name: s.appName,
                    downloadSpeed: 0, uploadSpeed: 0,
                    cumulativeDownload: s.totalIn, cumulativeUpload: s.totalOut,
                    proxyStatus: determineProxyStatus(for: s.appName)
                )
            }
        }

        // 短期查询走内存
        let since = period == .sinceStart ? startTime : now.addingTimeInterval(-period.seconds)
        var appTotals: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for record in trafficHistory {
            guard record.timestamp >= since else { continue }
            if let e = appTotals[record.appName] {
                appTotals[record.appName] = (e.bytesIn + record.bytesIn, e.bytesOut + record.bytesOut)
            } else {
                appTotals[record.appName] = (record.bytesIn, record.bytesOut)
            }
        }

        var result: [AppTraffic] = []
        for (name, totals) in appTotals {
            guard totals.bytesIn > 0 || totals.bytesOut > 0 else { continue }
            result.append(AppTraffic(
                id: name, name: name, downloadSpeed: 0, uploadSpeed: 0,
                cumulativeDownload: totals.bytesIn, cumulativeUpload: totals.bytesOut,
                proxyStatus: determineProxyStatus(for: name)
            ))
        }
        result.sort { $0.totalCumulative > $1.totalCumulative }
        return result
    }

    private func extractAppName(from processKey: String) -> String {
        let parts = processKey.split(separator: ".")
        if parts.count >= 2, let _ = Int(parts.last!) {
            return parts.dropLast().joined(separator: ".")
        }
        return processKey
    }

    /// 同步执行一次 nettop 并解析
    private func fetchNettopOnce() -> (
        stats: [String: (bytesIn: UInt64, bytesOut: UInt64)],
        interfaces: [String: Set<String>]
    ) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-x", "-l", "1", "-J", "bytes_in,bytes_out,interface"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return ([:], [:]) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return ([:], [:]) }
        return parseNettopOutput(output)
    }

    /// 解析 nettop 输出
    private func parseNettopOutput(_ output: String) -> (
        stats: [String: (bytesIn: UInt64, bytesOut: UInt64)],
        interfaces: [String: Set<String>]
    ) {
        var stats: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var interfaces: [String: Set<String>] = [:]
        var currentProcess: String? = nil

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("bytes_in") else { continue }

            let isConnectionLine = line.hasPrefix("   ") || line.hasPrefix("\t")

            if !isConnectionLine {
                let components = trimmed.split(separator: " ").map { String($0) }
                guard components.count >= 3 else { continue }

                let processName = components[0]
                guard let bytesOut = UInt64(components[components.count - 1]),
                      let bytesIn = UInt64(components[components.count - 2]) else { continue }

                if components.count >= 4 {
                    let ifaceName = components[components.count - 3]
                    if !ifaceName.contains(".") {
                        let appName = extractAppName(from: processName)
                        interfaces[appName, default: Set()].insert(ifaceName)
                    }
                }

                currentProcess = processName
                stats[processName] = (bytesIn: bytesIn, bytesOut: bytesOut)

            } else if let proc = currentProcess {
                let components = trimmed.split(separator: " ").map { String($0) }
                for component in components {
                    let comp = component.trimmingCharacters(in: .whitespaces)
                    if comp == "lo0" || comp.hasPrefix("en") || comp.hasPrefix("utun") ||
                       comp.hasPrefix("ipsec") || comp.hasPrefix("ppp") ||
                       comp.hasPrefix("tap") || comp.hasPrefix("tun") || comp.hasPrefix("bridge") {
                        let appName = extractAppName(from: proc)
                        interfaces[appName, default: Set()].insert(comp)
                    }
                }
            }
        }
        return (stats, interfaces)
    }
}
