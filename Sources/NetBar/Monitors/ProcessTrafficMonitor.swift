import AppKit
import Foundation

/// 按应用维度的流量监控器 — 整合 nettop 和 Mihomo 两个数据源
class ProcessTrafficMonitor: ObservableObject, MonitorProtocol {
    private static let maxActiveApps = 30
    private static let maxRankingApps = 60
    private static let routeHistoryRetention: TimeInterval = 3700
    private static let recentRouteLookback: TimeInterval = 6
    private static let shortTermCumulativeRefreshInterval: TimeInterval = 5
    private static let longTermCumulativeRefreshInterval: TimeInterval = 30

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

        var formattedDownload: String { Formatters.formatSpeed(downloadSpeed) }
        var formattedUpload: String { Formatters.formatSpeed(uploadSpeed) }
        var formattedCumulativeDown: String { Formatters.formatBytes(cumulativeDownload) }
        var formattedCumulativeUp: String { Formatters.formatBytes(cumulativeUpload) }
        var formattedCumulativeTotal: String { Formatters.formatBytes(totalCumulative) }
    }

    enum AppProxyStatus {
        case direct
        case proxied
        case mixed
        case unknown

        var label: String {
            switch self {
            case .direct: return L10n.Proxy.direct
            case .proxied: return L10n.Proxy.proxied
            case .mixed: return L10n.Proxy.mixed
            case .unknown: return L10n.Proxy.unknown
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

    private struct RouteSample {
        let timestamp: Date
        let appName: String
        let routeKind: RouteKind
    }

    private struct AppDelta {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var routeKinds: Set<RouteKind> = []
    }

    @Published private(set) var samplingMessage: String?
    @Published var appSpeeds: [AppTraffic] = []
    @Published var cumulativeRanking: [AppTraffic] = []
    @Published var selectedPeriod: TimePeriod = .fiveMinutes {
        didSet {
            guard selectedPeriod != oldValue else { return }
            requestCumulativeRefresh()
        }
    }

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
    private var hasNettopBaseline = false
    private var previousMihomoSnapshots: [String: MihomoClient.ConnectionSnapshot] = [:]
    private var previousTime: Date = Date()
    private var trafficHistory: [TrafficRecord] = []
    private var appInterfaces: [String: Set<String>] = [:]
    private var activeTunnelInterfaces: Set<String> = []
    private var routeHistory: [RouteSample] = []
    private let startTime = Date()
    private var cachedCumulativePeriod: TimePeriod?
    private var cachedCumulativeUpdatedAt: Date?

    private var timer: Timer?
    private let updateQueue = DispatchQueue(label: "com.zjah.NetBar.processTrafficMonitor", qos: .utility)
    private var sampling = ProcessSamplingSchedule()

    /// 持久化存储器
    var trafficStore: TrafficStore?

    init() {}

    func start() {
        start(interval: AppConfig.shared.refreshInterval)
    }

    func start(interval: TimeInterval) {
        sampling.requestedInterval = interval
        guard !sampling.isRunning else { scheduleNextSample(); return }
        sampling.start()
        // Baselines belong to the worker queue, never reset them under an active sample.
        updateQueue.async { [weak self] in
            guard let self else { return }
            self.previousStats = [:]
            self.hasNettopBaseline = false
            self.previousTime = Date()
            self.appInterfaces = [:]
            self.activeTunnelInterfaces = []
            self.previousMihomoSnapshots = [:]
        }
        scheduleNextSample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sampling.stop()
    }

    func restart(interval: TimeInterval) {
        // Changing cadence does not discard cumulative counter baselines.
        if !sampling.isRunning { start(interval: interval); return }
        sampling.requestedInterval = interval
        scheduleNextSample()
    }

    func setDetailVisible(_ visible: Bool) {
        guard sampling.isVisible != visible else { return }
        sampling.isVisible = visible
        scheduleNextSample()
    }

    private func scheduleNextSample() {
        timer?.invalidate()
        timer = nil
        guard sampling.isRunning, !sampling.isSampling else { return }
        let delay = max(0.01, sampling.waitTime(now: ProcessInfo.processInfo.systemUptime))
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.update() }
        next.tolerance = min(1, delay * 0.1)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    /// 手动触发累计排行刷新（供 UI 刷新按钮调用）
    func requestCumulativeRefresh() {
        let period = selectedPeriod
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            let cumulative = self.recomputeCumulativeRanking(period: period, now: Date())
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedPeriod == period else { return }
                self.cumulativeRanking = cumulative
            }
        }
    }

    // MARK: - 采样更新

    private func update() {
        guard let generation = sampling.begin(now: ProcessInfo.processInfo.systemUptime) else {
            scheduleNextSample()
            return
        }
        let selectedPeriod = selectedPeriod

        updateQueue.async { [weak self] in
            guard let self = self else { return }
            var succeeded = false
            defer {
                let sampleSucceeded = succeeded
                DispatchQueue.main.async {
                    if self.sampling.complete(generation: generation, succeeded: sampleSucceeded,
                                              now: ProcessInfo.processInfo.systemUptime) {
                        self.samplingMessage = sampleSucceeded ? nil : "应用流量采集暂时不可用，稍后自动重试"
                        if !sampleSucceeded { self.appSpeeds = [] }
                    }
                    self.scheduleNextSample()
                }
            }

            let nettopResult = NettopParser.fetchExternalSummary()
            guard !nettopResult.stats.isEmpty else { return }
            succeeded = true
            let activeTunnelInterfaces = TunnelRouteDetector.activeTunnelInterfaces()
            let currentMihomoSnapshots = MihomoClient.fetchConnectionSnapshots()
            let now = Date()
            let elapsed = now.timeIntervalSince(self.previousTime)
            guard elapsed > 0.5 else { return }

            self.appInterfaces = nettopResult.interfaces
            self.activeTunnelInterfaces = activeTunnelInterfaces

            guard self.hasNettopBaseline else {
                self.previousStats = nettopResult.stats
                self.previousTime = now
                self.hasNettopBaseline = true
                if let currentMihomoSnapshots {
                    self.previousMihomoSnapshots = currentMihomoSnapshots
                }
                return
            }

            var appDeltas: [String: AppDelta] = [:]
            var proxyCoreFallbackDeltas: [String: AppDelta] = [:]

            // nettop 只采集 external 接口。代理回环流量由 Mihomo API 按原应用补齐，避免本地 127.0.0.1
            // 代理连接被浏览器进程汇总成几十 MB/s 的假下载。
            for (key, val) in nettopResult.stats {
                let rawAppName = NettopParser.extractAppName(from: key)
                let appName = self.displayAppName(for: key, fallback: rawAppName)
                guard !self.isHiddenProcess(appName, includeProxyCore: false),
                      let previous = self.previousStats[key] else { continue }

                let dlBytes = val.bytesIn >= previous.bytesIn ? val.bytesIn - previous.bytesIn : 0
                let ulBytes = val.bytesOut >= previous.bytesOut ? val.bytesOut - previous.bytesOut : 0
                let routeKinds = self.routeKinds(
                    from: nettopResult.interfaces[appName] ?? nettopResult.interfaces[rawAppName],
                    activeTunnelInterfaces: activeTunnelInterfaces
                )
                let externalRouteKinds = routeKinds.isEmpty ? Set([RouteKind.direct]) : routeKinds

                if self.isProxyCoreProcess(appName) || self.isProxyCoreProcess(rawAppName) {
                    self.addDelta(
                        appName: self.proxyCoreDisplayName(for: appName),
                        bytesIn: dlBytes,
                        bytesOut: ulBytes,
                        routeKinds: [.proxied],
                        to: &proxyCoreFallbackDeltas
                    )
                } else {
                    self.addDelta(
                        appName: appName,
                        bytesIn: dlBytes,
                        bytesOut: ulBytes,
                        routeKinds: externalRouteKinds,
                        to: &appDeltas
                    )
                }
            }

            // Mihomo 增量
            if let currentMihomoSnapshots, !currentMihomoSnapshots.isEmpty {
                let currentRouteKinds = self.currentMihomoRouteKinds(from: currentMihomoSnapshots)
                for (appName, routeKinds) in currentRouteKinds where appDeltas[appName] != nil {
                    self.addDelta(
                        appName: appName,
                        bytesIn: 0,
                        bytesOut: 0,
                        routeKinds: routeKinds,
                        to: &appDeltas
                    )
                }

                let mihomoDeltas = self.computeMihomoDeltas(
                    current: currentMihomoSnapshots,
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
                self.previousMihomoSnapshots = currentMihomoSnapshots
            } else if appDeltas.isEmpty {
                for (appName, delta) in proxyCoreFallbackDeltas {
                    self.addDelta(
                        appName: appName,
                        bytesIn: delta.bytesIn,
                        bytesOut: delta.bytesOut,
                        routeKinds: delta.routeKinds,
                        to: &appDeltas
                    )
                }
            }

            // 构建实时速度列表
            var speeds: [AppTraffic] = []
            var trafficIncrements: [TrafficStore.TrafficIncrement] = []
            for (appName, delta) in appDeltas {
                guard !self.isHiddenProcess(appName) else { continue }

                if !delta.routeKinds.isEmpty {
                    self.recordRouteKinds(delta.routeKinds, for: appName, at: now)
                }

                let dlSpeed = Double(delta.bytesIn) / elapsed
                let ulSpeed = Double(delta.bytesOut) / elapsed

                if delta.bytesIn > 0 || delta.bytesOut > 0 {
                    self.trafficHistory.append(TrafficRecord(
                        timestamp: now, appName: appName, bytesIn: delta.bytesIn, bytesOut: delta.bytesOut
                    ))
                    trafficIncrements.append(TrafficStore.TrafficIncrement(
                        appName: appName,
                        bytesIn: delta.bytesIn,
                        bytesOut: delta.bytesOut
                    ))
                }

                if dlSpeed > 10 || ulSpeed > 10 {
                    speeds.append(AppTraffic(
                        id: appName, name: appName,
                        downloadSpeed: dlSpeed, uploadSpeed: ulSpeed,
                        cumulativeDownload: 0, cumulativeUpload: 0,
                        proxyStatus: self.proxyStatus(
                            for: appName,
                            currentRouteKinds: delta.routeKinds,
                            since: now.addingTimeInterval(-Self.recentRouteLookback)
                        )
                    ))
                }
            }

            self.trafficStore?.recordBatch(trafficIncrements)
            speeds.sort { $0.totalSpeed > $1.totalSpeed }
            speeds = Array(speeds.prefix(Self.maxActiveApps))
            let cutoff = now.addingTimeInterval(-Self.routeHistoryRetention)
            self.trafficHistory.removeAll { $0.timestamp < cutoff }
            self.routeHistory.removeAll { $0.timestamp < cutoff }
            let cumulative = self.refreshCumulativeRankingIfNeeded(period: selectedPeriod, now: now)

            DispatchQueue.main.async {
                guard self.sampling.isRunning, self.sampling.generation == generation else { return }
                self.appSpeeds = speeds
                if let cumulative, self.selectedPeriod == selectedPeriod {
                    self.cumulativeRanking = cumulative
                }
            }

            self.previousStats = nettopResult.stats
            self.previousTime = now
        }
    }

    // MARK: - Mihomo 增量计算

    private func computeMihomoDeltas(
        current: [String: MihomoClient.ConnectionSnapshot],
        since previousSampleTime: Date
    ) -> [String: AppDelta] {
        var deltas: [String: AppDelta] = [:]

        for (id, snapshot) in current {
            let dlBytes: UInt64
            let ulBytes: UInt64

            if let previous = previousMihomoSnapshots[id], previous.appName == snapshot.appName {
                dlBytes = snapshot.bytesIn >= previous.bytesIn ? snapshot.bytesIn - previous.bytesIn : snapshot.bytesIn
                ulBytes = snapshot.bytesOut >= previous.bytesOut ? snapshot.bytesOut - previous.bytesOut : snapshot.bytesOut
            } else if let startDate = snapshot.startDate, startDate >= previousSampleTime.addingTimeInterval(-1) {
                dlBytes = snapshot.bytesIn
                ulBytes = snapshot.bytesOut
            } else {
                continue
            }

            let routeKind: RouteKind = snapshot.isDirect ? .direct : .proxied
            addDelta(
                appName: canonicalAppDisplayName(snapshot.appName),
                bytesIn: dlBytes,
                bytesOut: ulBytes,
                routeKind: routeKind,
                to: &deltas
            )
        }

        return deltas
    }

    // MARK: - 代理状态判断

    private func proxyStatus(
        for appName: String,
        currentRouteKinds: Set<RouteKind> = [],
        since: Date
    ) -> AppProxyStatus {
        if !currentRouteKinds.isEmpty {
            return proxyStatus(from: currentRouteKinds)
        }

        let historyKinds = routeKinds(for: appName, since: since)
        if !historyKinds.isEmpty {
            return proxyStatus(from: historyKinds)
        }

        let interfaceKinds = routeKinds(
            from: appInterfaces[appName],
            activeTunnelInterfaces: activeTunnelInterfaces
        )
        if !interfaceKinds.isEmpty {
            return proxyStatus(from: interfaceKinds)
        }

        return .unknown
    }

    private func proxyStatus(from routeKinds: Set<RouteKind>) -> AppProxyStatus {
        let hasDirect = routeKinds.contains(.direct)
        let hasProxied = routeKinds.contains(.proxied)

        if hasDirect && hasProxied { return .mixed }
        if hasProxied { return .proxied }
        if hasDirect { return .direct }
        return .unknown
    }

    private func routeKinds(for appName: String, since: Date) -> Set<RouteKind> {
        Set(routeHistory.lazy
            .filter { $0.appName == appName && $0.timestamp >= since }
            .map(\.routeKind))
    }

    private func routeKinds(
        from interfaces: Set<String>?,
        activeTunnelInterfaces: Set<String>
    ) -> Set<RouteKind> {
        guard let interfaces else { return [] }

        let nonLoopback = interfaces.filter { $0 != "lo0" && !$0.isEmpty }
        guard !nonLoopback.isEmpty else { return [] }

        var kinds: Set<RouteKind> = []
        for iface in nonLoopback {
            if isVPNInterface(iface) {
                if activeTunnelInterfaces.contains(iface) {
                    kinds.insert(.proxied)
                }
            } else {
                kinds.insert(.direct)
            }
        }
        return kinds
    }

    private func isVPNInterface(_ iface: String) -> Bool {
        TunnelRouteDetector.isVPNInterfaceName(iface)
    }

    private func recordRouteKinds(_ routeKinds: Set<RouteKind>, for appName: String, at timestamp: Date) {
        for routeKind in routeKinds {
            routeHistory.append(RouteSample(timestamp: timestamp, appName: appName, routeKind: routeKind))
        }
    }

    // MARK: - 累计排行

    private func routeStatusStart(for period: TimePeriod, now: Date) -> Date {
        let retainedStart = now.addingTimeInterval(-Self.routeHistoryRetention)
        let desiredStart: Date

        switch period {
        case .oneMinute, .fiveMinutes, .oneHour:
            desiredStart = now.addingTimeInterval(-period.seconds)
        case .sinceStart:
            desiredStart = startTime
        case .today:
            desiredStart = Calendar.current.startOfDay(for: now)
        case .sevenDays:
            desiredStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .thirtyDays:
            desiredStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .thisMonth:
            let components = Calendar.current.dateComponents([.year, .month], from: now)
            desiredStart = Calendar.current.date(from: components) ?? retainedStart
        }

        return max(desiredStart, retainedStart)
    }

    private func refreshCumulativeRankingIfNeeded(period: TimePeriod, now: Date) -> [AppTraffic]? {
        let refreshInterval = cumulativeRefreshInterval(for: period)
        if cachedCumulativePeriod == period,
           let cachedCumulativeUpdatedAt,
           now.timeIntervalSince(cachedCumulativeUpdatedAt) < refreshInterval {
            return nil
        }

        return recomputeCumulativeRanking(period: period, now: now)
    }

    private func recomputeCumulativeRanking(period: TimePeriod, now: Date) -> [AppTraffic] {
        let result = computeCumulativeRanking(period: period, now: now)
        cachedCumulativePeriod = period
        cachedCumulativeUpdatedAt = now
        return result
    }

    private func cumulativeRefreshInterval(for period: TimePeriod) -> TimeInterval {
        period.isLongTerm || period == .sinceStart
            ? Self.longTermCumulativeRefreshInterval
            : Self.shortTermCumulativeRefreshInterval
    }

    private func computeCumulativeRanking(period: TimePeriod, now: Date) -> [AppTraffic] {
        let routeSince = routeStatusStart(for: period, now: now)

        // 长期查询走持久化存储
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
                    proxyStatus: proxyStatus(for: s.appName, since: routeSince)
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
                proxyStatus: proxyStatus(for: name, since: routeSince)
            ))
        }
        result.sort { $0.totalCumulative > $1.totalCumulative }
        return Array(result.prefix(Self.maxRankingApps))
    }

    // MARK: - 辅助方法

    private func currentMihomoRouteKinds(
        from snapshots: [String: MihomoClient.ConnectionSnapshot]
    ) -> [String: Set<RouteKind>] {
        var result: [String: Set<RouteKind>] = [:]
        for snapshot in snapshots.values {
            let appName = canonicalAppDisplayName(snapshot.appName)
            guard !appName.isEmpty else { continue }
            result[appName, default: []].insert(snapshot.isDirect ? .direct : .proxied)
        }
        return result
    }

    private func displayAppName(for processKey: String, fallback: String) -> String {
        if let pid = processID(from: processKey),
           let localizedName = NSRunningApplication(processIdentifier: pid)?
            .localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !localizedName.isEmpty {
            return canonicalAppDisplayName(localizedName)
        }

        return canonicalAppDisplayName(fallback)
    }

    private func processID(from processKey: String) -> pid_t? {
        guard let pidText = processKey.split(separator: ".").last,
              let pid = Int32(pidText) else {
            return nil
        }
        return pid
    }

    private func canonicalAppDisplayName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [
            " Helper (Renderer)",
            " Helper (Plugin)",
            " Helper (GPU)",
            " Helper (Pl",
            " Helper",
            " Helpe",
            " Hel",
            " H"
        ]

        for suffix in suffixes where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        switch result.lowercased() {
        case "codex":
            return "Codex"
        case "clash-verge":
            return "Clash Verge"
        case "verge-mihomo", "mihomo":
            return "Mihomo"
        default:
            return result
        }
    }

    private func isHiddenProcess(_ appName: String, includeProxyCore: Bool = true) -> Bool {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerName = name.lowercased()
        let isSystemHidden = hiddenProcesses.contains { $0.lowercased() == lowerName }
        guard includeProxyCore else { return isSystemHidden && !isProxyCoreProcess(name) }
        return isSystemHidden || isProxyCoreProcess(name)
    }

    private func isProxyCoreProcess(_ appName: String) -> Bool {
        let lowerName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return proxyCoreProcesses.contains { $0.lowercased() == lowerName }
    }

    private func proxyCoreDisplayName(for appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "代理核心" : "代理核心 \(trimmed)"
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
}
