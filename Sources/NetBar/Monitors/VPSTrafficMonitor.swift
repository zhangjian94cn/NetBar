import Foundation

/// VPS 流量监控器 — 通过 3X-UI API 定时获取 VPS 流量统计
class VPSTrafficMonitor: ObservableObject, MonitorProtocol {

    /// 单个 VPS 的流量数据
    struct VPSTraffic: Identifiable {
        let id: String
        let name: String
        var upload: UInt64
        var download: UInt64
        var total: UInt64
        var totalLimit: UInt64
        var protocol_: String
        var port: Int
        var clients: [ClientTraffic]
        var lastUpdated: Date?
        var isOnline: Bool
        var error: String?

        var formattedUpload: String { Formatters.formatBytes(upload) }
        var formattedDownload: String { Formatters.formatBytes(download) }
        var formattedTotal: String { Formatters.formatBytes(total) }
        var formattedLimit: String { totalLimit == 0 ? "∞" : Formatters.formatBytes(totalLimit) }
        var lastUpdatedText: String {
            guard let last = lastUpdated else { return "未连接" }
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 60 { return "\(Int(elapsed))s 前" }
            else if elapsed < 3600 { return "\(Int(elapsed / 60))m 前" }
            else { return "\(Int(elapsed / 3600))h 前" }
        }
    }

    /// 客户端流量
    struct ClientTraffic: Identifiable {
        let id: String
        let email: String
        var upload: UInt64
        var download: UInt64
        var total: UInt64
        var isOnline: Bool
    }

    @Published var vpsList: [VPSTraffic] = []

    private var configs: [AppConfig.VPSConfig] = []
    private var sessionCookies: [String: String] = [:]
    private let stateQueue = DispatchQueue(label: "com.zjah.NetBar.vpsTrafficMonitor.state")
    private let client = ThreeXUIClient()
    private var timer: Timer?

    init() {
        configs = Self.loadConfigsFromAppConfig()
        logLoadedConfigs()
    }

    private static func loadConfigsFromAppConfig() -> [AppConfig.VPSConfig] {
        AppConfig.shared.vpsConfigs
    }

    private func logLoadedConfigs() {
        let count = stateQueue.sync { configs.count }
        if count == 0 {
            Log.vps.info("未配置 VPS 信息，VPS 流量监控跳过")
        } else {
            Log.vps.info("已加载 \(count) 个 VPS 配置")
        }
    }

    func reloadConfigs() {
        let newConfigs = Self.loadConfigsFromAppConfig()
        let validIDs = Set(newConfigs.map(\.id))

        stateQueue.async {
            self.configs = newConfigs
            self.sessionCookies = self.sessionCookies.filter { validIDs.contains($0.key) }

            DispatchQueue.main.async {
                self.vpsList.removeAll { !validIDs.contains($0.id) }
            }

            if newConfigs.isEmpty {
                Log.vps.info("未配置 VPS 信息，VPS 流量监控跳过")
            } else {
                Log.vps.info("已重新加载 \(newConfigs.count) 个 VPS 配置")
            }
            self.fetchAll(configs: newConfigs)
        }
    }

    func start() {
        start(interval: 60.0)
    }

    func start(interval: TimeInterval) {
        fetchAll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchAll()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        fetchAll()
    }

    // MARK: - 网络请求

    private func fetchAll() {
        let configsSnapshot = stateQueue.sync { configs }
        fetchAll(configs: configsSnapshot)
    }

    private func fetchAll(configs configsSnapshot: [AppConfig.VPSConfig]) {
        for config in configsSnapshot {
            Task.detached(priority: .utility) { [weak self] in
                await self?.fetchVPSTraffic(config: config)
            }
        }
    }

    private func cookie(for configID: String) -> String? {
        stateQueue.sync { sessionCookies[configID] }
    }

    private func setCookie(_ cookie: String, for configID: String) {
        stateQueue.async {
            guard self.configs.contains(where: { $0.id == configID }) else { return }
            self.sessionCookies[configID] = cookie
        }
    }

    private func removeCookie(for configID: String) {
        stateQueue.async {
            self.sessionCookies.removeValue(forKey: configID)
        }
    }

    private func containsConfig(id: String) -> Bool {
        stateQueue.sync {
            configs.contains { $0.id == id }
        }
    }

    private func fetchVPSTraffic(config: AppConfig.VPSConfig) async {
        guard !config.password.isEmpty else {
            updateError(config: config, error: VPSConnectionError.passwordRequired.localizedDescription)
            return
        }

        if let cookie = cookie(for: config.id) {
            do {
                let traffic = try await client.fetchInbounds(config: config, cookie: cookie)
                updateTraffic(config: config, traffic: traffic)
                return
            } catch {
                removeCookie(for: config.id)
            }
        }

        do {
            let cookie = try await client.login(config: config, password: config.password)
            setCookie(cookie, for: config.id)
            let traffic = try await client.fetchInbounds(config: config, cookie: cookie)
            updateTraffic(config: config, traffic: traffic)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            updateError(config: config, error: message)
        }
    }

    // MARK: - 数据更新

    private func updateTraffic(config: AppConfig.VPSConfig, traffic: [ThreeXUIInboundData]) {
        guard containsConfig(id: config.id) else { return }

        let now = Date()
        var totalUp: UInt64 = 0
        var totalDown: UInt64 = 0
        var totalAll: UInt64 = 0
        var totalLimit: UInt64 = 0
        var allClients: [ClientTraffic] = []
        var protocol_ = ""
        var port = 0

        for inbound in traffic {
            totalUp += inbound.up
            totalDown += inbound.down
            totalAll += inbound.allTime
            totalLimit += inbound.total
            protocol_ = inbound.protocol_
            port = inbound.port

            for client in inbound.clients {
                let isOnline = now.timeIntervalSince1970 * 1000 - Double(client.lastOnline) < 300_000
                allClients.append(ClientTraffic(
                    id: client.email,
                    email: client.email,
                    upload: client.up,
                    download: client.down,
                    total: client.allTime,
                    isOnline: isOnline
                ))
            }
        }

        let hasOnlineClient = allClients.contains { $0.isOnline }
        let vpsTraffic = VPSTraffic(
            id: config.id,
            name: config.name,
            upload: totalUp,
            download: totalDown,
            total: totalAll,
            totalLimit: totalLimit,
            protocol_: protocol_,
            port: port,
            clients: allClients,
            lastUpdated: now,
            isOnline: hasOnlineClient,
            error: nil
        )

        DispatchQueue.main.async {
            if let idx = self.vpsList.firstIndex(where: { $0.id == config.id }) {
                self.vpsList[idx] = vpsTraffic
            } else {
                self.vpsList.append(vpsTraffic)
            }
        }
    }

    private func updateError(config: AppConfig.VPSConfig, error: String) {
        guard containsConfig(id: config.id) else { return }

        DispatchQueue.main.async {
            if let idx = self.vpsList.firstIndex(where: { $0.id == config.id }) {
                self.vpsList[idx].error = error
                self.vpsList[idx].lastUpdated = Date()
            } else {
                self.vpsList.append(VPSTraffic(
                    id: config.id,
                    name: config.name,
                    upload: 0,
                    download: 0,
                    total: 0,
                    totalLimit: 0,
                    protocol_: "",
                    port: 0,
                    clients: [],
                    lastUpdated: Date(),
                    isOnline: false,
                    error: error
                ))
            }
        }
    }
}
