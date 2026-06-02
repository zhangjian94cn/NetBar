import Foundation

/// 按应用维度的流量监控器 — 通过长连接 nettop 流式解析
class ProcessTrafficMonitor: ObservableObject {
    private static let maxActiveApps = 30
    private static let maxRankingApps = 60
    private static let mihomoSocketPath = "/tmp/verge/verge-mihomo.sock"
    private static let mihomoControllerURL = "http://127.0.0.1:9097/connections"
    private static let mihomoSecret = "set-your-secret"

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

    private enum RouteKind: Hashable {
        case direct
        case proxied
    }

    private struct AppDelta {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var routeKinds: Set<RouteKind> = []
    }

    private struct MihomoConnectionsResponse: Decodable {
        let connections: [MihomoConnection]
    }

    private struct MihomoConnection: Decodable {
        let id: String
        let metadata: MihomoMetadata
        let upload: UInt64
        let download: UInt64
        let start: String?
        let chains: [String]?
    }

    private struct MihomoMetadata: Decodable {
        let process: String?
        let processPath: String?
        let host: String?
    }

    private struct MihomoConnectionSnapshot {
        let appName: String
        let bytesIn: UInt64
        let bytesOut: UInt64
        let routeKind: RouteKind
        let startDate: Date?
    }

    @Published var appSpeeds: [AppTraffic] = []
    @Published var cumulativeRanking: [AppTraffic] = []
    @Published var selectedPeriod: TimePeriod = .fiveMinutes

    private let vpnPrefixes = ["utun", "ipsec", "ppp", "tap", "tun"]
    private let proxyCoreProcesses: Set<String> = [
        "clash", "Clash Verge", "clash-verge", "mihomo", "verge-mihomo"
    ]
    private let hiddenProcesses: Set<String> = [
        "launchd", "configd", "syslogd", "kdc", "airportd",
        "wifianalyticsd", "identityserviced", "rapportd",
        "sharingd", "ControlCenter", "wifivelocityd",
        "netbiosd", "wifip2pd", "mDNSResponder", "apsd",
        "identityservice", "trustd", "ARDAgent",
        "clash", "Clash Verge", "clash-verge", "mihomo", "verge-mihomo"
    ]

    private var previousStats: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var previousMihomoConnections: [String: MihomoConnectionSnapshot] = [:]
    private var previousTime: Date = Date()
    private var trafficHistory: [TrafficRecord] = []
    private var appInterfaces: [String: Set<String>] = [:]
    private var appRouteKinds: [String: Set<RouteKind>] = [:]
    private let startTime = Date()

    // 流式 nettop
    private var nettopProcess: Process?
    private var nettopPipe: Pipe?
    private var outputBuffer: String = ""
    private var timer: Timer?
    private let updateQueue = DispatchQueue(label: "com.zjah.NetBar.processTrafficMonitor", qos: .utility)
    private var updateInProgress = false

    /// 持久化存储器
    var trafficStore: TrafficStore?

    init() {}

    func start(interval: TimeInterval = 2.0) {
        // 先获取一次基线数据（同步方式）
        let (stats, interfaces) = fetchNettopOnce()
        previousStats = stats
        previousTime = Date()
        appInterfaces = interfaces
        previousMihomoConnections = fetchMihomoConnectionSnapshots() ?? [:]

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
        guard !updateInProgress else { return }
        updateInProgress = true
        let selectedPeriod = selectedPeriod

        updateQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.updateInProgress = false
                }
            }

            let (currentStats, interfaces) = self.fetchNettopOnce()
            let currentMihomoConnections = self.fetchMihomoConnectionSnapshots()
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

            var appDeltas: [String: AppDelta] = [:]

            for (key, val) in currentStats {
                let appName = self.extractAppName(from: key)
                guard !self.isHiddenProcess(appName),
                      let previous = self.previousStats[key] else { continue }

                let dlBytes = val.bytesIn >= previous.bytesIn ? val.bytesIn - previous.bytesIn : 0
                let ulBytes = val.bytesOut >= previous.bytesOut ? val.bytesOut - previous.bytesOut : 0
                self.addDelta(appName: appName, bytesIn: dlBytes, bytesOut: ulBytes, routeKind: nil, to: &appDeltas)
            }

            if let currentMihomoConnections {
                let mihomoDeltas = self.computeMihomoDeltas(
                    current: currentMihomoConnections,
                    since: self.previousTime
                )
                for (appName, delta) in mihomoDeltas {
                    guard !self.isHiddenProcess(appName) else { continue }
                    self.addDelta(
                        appName: appName,
                        bytesIn: delta.bytesIn,
                        bytesOut: delta.bytesOut,
                        routeKinds: delta.routeKinds,
                        to: &appDeltas
                    )
                }
                self.previousMihomoConnections = currentMihomoConnections
            }

            var speeds: [AppTraffic] = []
            for (appName, delta) in appDeltas {
                guard !self.isHiddenProcess(appName) else { continue }

                if !delta.routeKinds.isEmpty {
                    self.appRouteKinds[appName, default: Set()].formUnion(delta.routeKinds)
                }

                let dlSpeed = Double(delta.bytesIn) / elapsed
                let ulSpeed = Double(delta.bytesOut) / elapsed

                if delta.bytesIn > 0 || delta.bytesOut > 0 {
                    self.trafficHistory.append(TrafficRecord(
                        timestamp: now, appName: appName, bytesIn: delta.bytesIn, bytesOut: delta.bytesOut
                    ))
                    // 持久化到磁盘
                    self.trafficStore?.record(appName: appName, bytesIn: delta.bytesIn, bytesOut: delta.bytesOut)
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

            speeds.sort { $0.totalSpeed > $1.totalSpeed }
            speeds = Array(speeds.prefix(Self.maxActiveApps))
            let cutoff = now.addingTimeInterval(-3700)
            self.trafficHistory.removeAll { $0.timestamp < cutoff }
            let cumulative = self.computeCumulativeRanking(period: selectedPeriod, now: now)

            DispatchQueue.main.async {
                self.appSpeeds = speeds
                self.cumulativeRanking = cumulative
            }

            self.previousStats = currentStats
            self.previousTime = now
        }
    }

    private func determineProxyStatus(for appName: String) -> AppProxyStatus {
        if let routeKinds = appRouteKinds[appName], !routeKinds.isEmpty {
            let hasDirect = routeKinds.contains(.direct)
            let hasProxied = routeKinds.contains(.proxied)

            if hasDirect && hasProxied { return .mixed }
            if hasProxied { return .proxied }
            if hasDirect { return .direct }
        }

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
            return summaries.filter { !isHiddenProcess($0.appName) }.map { s in
                AppTraffic(
                    id: s.appName, name: s.appName,
                    downloadSpeed: 0, uploadSpeed: 0,
                    cumulativeDownload: s.totalIn, cumulativeUpload: s.totalOut,
                    proxyStatus: determineProxyStatus(for: s.appName)
                )
            }
            .prefix(Self.maxRankingApps)
            .map { $0 }
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
            guard !isHiddenProcess(name) else { continue }
            guard totals.bytesIn > 0 || totals.bytesOut > 0 else { continue }
            result.append(AppTraffic(
                id: name, name: name, downloadSpeed: 0, uploadSpeed: 0,
                cumulativeDownload: totals.bytesIn, cumulativeUpload: totals.bytesOut,
                proxyStatus: determineProxyStatus(for: name)
            ))
        }
        result.sort { $0.totalCumulative > $1.totalCumulative }
        return Array(result.prefix(Self.maxRankingApps))
    }

    private func extractAppName(from processKey: String) -> String {
        let parts = processKey.split(separator: ".")
        if parts.count >= 2, let _ = Int(parts.last!) {
            return parts.dropLast().joined(separator: ".")
        }
        return processKey
    }

    private func isHiddenProcess(_ appName: String) -> Bool {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hiddenProcesses.contains(name) ||
            hiddenProcesses.contains(name.lowercased()) ||
            proxyCoreProcesses.contains(name) ||
            proxyCoreProcesses.contains(name.lowercased())
    }

    private func addDelta(
        appName: String,
        bytesIn: UInt64,
        bytesOut: UInt64,
        routeKind: RouteKind?,
        to deltas: inout [String: AppDelta]
    ) {
        var delta = deltas[appName] ?? AppDelta()
        delta.bytesIn += bytesIn
        delta.bytesOut += bytesOut
        if let routeKind {
            delta.routeKinds.insert(routeKind)
        }
        deltas[appName] = delta
    }

    private func addDelta(
        appName: String,
        bytesIn: UInt64,
        bytesOut: UInt64,
        routeKinds: Set<RouteKind>,
        to deltas: inout [String: AppDelta]
    ) {
        var delta = deltas[appName] ?? AppDelta()
        delta.bytesIn += bytesIn
        delta.bytesOut += bytesOut
        delta.routeKinds.formUnion(routeKinds)
        deltas[appName] = delta
    }

    private func computeMihomoDeltas(
        current: [String: MihomoConnectionSnapshot],
        since previousSampleTime: Date
    ) -> [String: AppDelta] {
        var deltas: [String: AppDelta] = [:]

        for (id, snapshot) in current {
            let dlBytes: UInt64
            let ulBytes: UInt64

            if let previous = previousMihomoConnections[id], previous.appName == snapshot.appName {
                dlBytes = snapshot.bytesIn >= previous.bytesIn ? snapshot.bytesIn - previous.bytesIn : snapshot.bytesIn
                ulBytes = snapshot.bytesOut >= previous.bytesOut ? snapshot.bytesOut - previous.bytesOut : snapshot.bytesOut
            } else if let startDate = snapshot.startDate, startDate >= previousSampleTime.addingTimeInterval(-1) {
                dlBytes = snapshot.bytesIn
                ulBytes = snapshot.bytesOut
            } else {
                continue
            }

            addDelta(
                appName: snapshot.appName,
                bytesIn: dlBytes,
                bytesOut: ulBytes,
                routeKind: snapshot.routeKind,
                to: &deltas
            )
        }

        return deltas
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

    private func fetchMihomoConnectionSnapshots() -> [String: MihomoConnectionSnapshot]? {
        guard let data = fetchMihomoConnectionsData() else { return nil }

        do {
            let response = try JSONDecoder().decode(MihomoConnectionsResponse.self, from: data)
            var snapshots: [String: MihomoConnectionSnapshot] = [:]

            for connection in response.connections {
                let appName = appNameFromMihomoMetadata(connection.metadata)
                guard !appName.isEmpty, !isHiddenProcess(appName) else { continue }

                snapshots[connection.id] = MihomoConnectionSnapshot(
                    appName: appName,
                    bytesIn: connection.download,
                    bytesOut: connection.upload,
                    routeKind: routeKind(for: connection),
                    startDate: parseMihomoDate(connection.start)
                )
            }

            return snapshots
        } catch {
            return nil
        }
    }

    private func fetchMihomoConnectionsData() -> Data? {
        if FileManager.default.fileExists(atPath: Self.mihomoSocketPath),
           let data = runCurl(arguments: [
                "-sS", "--max-time", "1",
                "--unix-socket", Self.mihomoSocketPath,
                "-H", "Authorization: Bearer \(Self.mihomoSecret)",
                "http://unix/connections"
           ]) {
            return data
        }

        return runCurl(arguments: [
            "-sS", "--max-time", "1",
            "-H", "Authorization: Bearer \(Self.mihomoSecret)",
            Self.mihomoControllerURL
        ])
    }

    private func runCurl(arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private func appNameFromMihomoMetadata(_ metadata: MihomoMetadata) -> String {
        if let processPath = metadata.processPath,
           let appName = appBundleName(from: processPath) {
            return appName
        }

        if let process = metadata.process?.trimmingCharacters(in: .whitespacesAndNewlines),
           !process.isEmpty {
            return extractAppName(from: process)
        }

        if let host = metadata.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }

        return "未知代理应用"
    }

    private func appBundleName(from processPath: String) -> String? {
        for component in processPath.split(separator: "/") {
            guard component.hasSuffix(".app") else { continue }
            return String(component.dropLast(4))
        }
        return nil
    }

    private func routeKind(for connection: MihomoConnection) -> RouteKind {
        if connection.chains?.contains(where: { $0.localizedCaseInsensitiveContains("DIRECT") }) == true {
            return .direct
        }
        return .proxied
    }

    private func parseMihomoDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// 解析 nettop 输出
    private func parseNettopOutput(_ output: String) -> (
        stats: [String: (bytesIn: UInt64, bytesOut: UInt64)],
        interfaces: [String: Set<String>]
    ) {
        var summaryStats: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var connectionStats: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var processesWithConnectionStats: Set<String> = []
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
                summaryStats[processName] = (bytesIn: bytesIn, bytesOut: bytesOut)

            } else if let proc = currentProcess {
                guard let parsed = parseConnectionTrafficLine(trimmed) else { continue }

                processesWithConnectionStats.insert(proc)
                if let iface = parsed.interface {
                    let appName = extractAppName(from: proc)
                    interfaces[appName, default: Set()].insert(iface)
                }

                guard shouldCountRawConnection(processName: proc, line: trimmed, interface: parsed.interface) else {
                    continue
                }

                if let existing = connectionStats[proc] {
                    connectionStats[proc] = (
                        existing.bytesIn + parsed.bytesIn,
                        existing.bytesOut + parsed.bytesOut
                    )
                } else {
                    connectionStats[proc] = (parsed.bytesIn, parsed.bytesOut)
                }
            }
        }

        var stats = connectionStats
        for (processName, summary) in summaryStats where !processesWithConnectionStats.contains(processName) {
            guard !isHiddenProcess(extractAppName(from: processName)) else { continue }
            stats[processName] = summary
        }

        return (stats, interfaces)
    }

    private func parseConnectionTrafficLine(_ line: String) -> (
        interface: String?,
        bytesIn: UInt64,
        bytesOut: UInt64
    )? {
        let components = line.split(separator: " ").map { String($0) }
        guard components.count >= 3,
              let bytesOut = UInt64(components[components.count - 1]),
              let bytesIn = UInt64(components[components.count - 2]) else {
            return nil
        }

        let interfaceCandidate = components[components.count - 3]
        let interface = isInterfaceName(interfaceCandidate) ? interfaceCandidate : nil
        return (interface, bytesIn, bytesOut)
    }

    private func shouldCountRawConnection(processName: String, line: String, interface: String?) -> Bool {
        let appName = extractAppName(from: processName)
        guard !isHiddenProcess(appName) else { return false }
        guard interface != "lo0" else { return false }
        guard !line.contains("198.18.") else { return false }
        guard !line.contains("fdfe:dcba:9876") else { return false }
        return true
    }

    private func isInterfaceName(_ value: String) -> Bool {
        value == "lo0" ||
            value.hasPrefix("en") ||
            value.hasPrefix("awdl") ||
            value.hasPrefix("llw") ||
            value.hasPrefix("utun") ||
            value.hasPrefix("ipsec") ||
            value.hasPrefix("ppp") ||
            value.hasPrefix("tap") ||
            value.hasPrefix("tun") ||
            value.hasPrefix("bridge")
    }
}
