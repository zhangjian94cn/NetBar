import Foundation

/// VPS 流量监控器 — 通过 3X-UI API 定时获取 VPS 流量统计
class VPSTrafficMonitor: ObservableObject {

    /// 单个 VPS 的流量数据
    struct VPSTraffic: Identifiable {
        let id: String          // VPS 标识
        let name: String        // 显示名称
        var upload: UInt64      // 上传字节数
        var download: UInt64    // 下载字节数
        var total: UInt64       // 总计
        var totalLimit: UInt64  // 流量限额（0 = 无限）
        var protocol_: String   // 协议名称
        var port: Int           // 端口
        var clients: [ClientTraffic]
        var lastUpdated: Date?
        var isOnline: Bool
        var error: String?

        var formattedUpload: String { formatBytes(upload) }
        var formattedDownload: String { formatBytes(download) }
        var formattedTotal: String { formatBytes(total) }
        var formattedLimit: String { totalLimit == 0 ? "∞" : formatBytes(totalLimit) }
        var lastUpdatedText: String {
            guard let last = lastUpdated else { return "未连接" }
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 60 { return "\(Int(elapsed))s 前" }
            else if elapsed < 3600 { return "\(Int(elapsed / 60))m 前" }
            else { return "\(Int(elapsed / 3600))h 前" }
        }

        private func formatBytes(_ bytes: UInt64) -> String {
            let b = Double(bytes)
            if b < 1024 { return String(format: "%.0f B", b) }
            else if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
            else if b < 1024 * 1024 * 1024 { return String(format: "%.2f MB", b / (1024 * 1024)) }
            else { return String(format: "%.2f GB", b / (1024 * 1024 * 1024)) }
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

    /// VPS 连接配置
    struct VPSConfig {
        let id: String
        let name: String
        let host: String
        let port: Int
        let basePath: String
        let username: String
        let password: String
        let useTLS: Bool

        var baseURL: String {
            let scheme = useTLS ? "https" : "http"
            return "\(scheme)://\(host):\(port)/\(basePath)"
        }
    }

    @Published var vpsList: [VPSTraffic] = []

    private var configs: [VPSConfig] = []
    private var sessionCookies: [String: String] = [:]  // configId -> cookie
    private var timer: Timer?

    init() {
        loadDefaultConfig()
    }

    /// 从 UserDefaults 加载 VPS 配置（无硬编码默认值）
    /// 首次使用需通过 defaults write com.zjah.NetBar vps_bwg_host "x.x.x.x" 等命令配置
    private func loadDefaultConfig() {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: "vps_bwg_host"),
              let username = defaults.string(forKey: "vps_bwg_user"),
              let password = defaults.string(forKey: "vps_bwg_pass") else {
            // 未配置 VPS 信息，跳过
            return
        }
        let port = defaults.integer(forKey: "vps_bwg_port") != 0 ? defaults.integer(forKey: "vps_bwg_port") : 2053
        let basePath = defaults.string(forKey: "vps_bwg_path") ?? ""

        configs = [
            VPSConfig(
                id: "bwg-cn2gia",
                name: "BWG-CN2GIA",
                host: host,
                port: port,
                basePath: basePath,
                username: username,
                password: password,
                useTLS: true
            )
        ]
    }

    func start(interval: TimeInterval = 60.0) {
        // 立即获取一次
        fetchAll()
        // 定时刷新
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
        for config in configs {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.fetchVPSTraffic(config: config)
            }
        }
    }

    private func fetchVPSTraffic(config: VPSConfig) {
        // 先尝试用已有 cookie 获取数据
        if let cookie = sessionCookies[config.id] {
            if let traffic = fetchInbounds(config: config, cookie: cookie) {
                updateTraffic(config: config, traffic: traffic)
                return
            }
        }

        // Cookie 失效，重新登录
        guard let cookie = login(config: config) else {
            updateError(config: config, error: "登录失败")
            return
        }
        sessionCookies[config.id] = cookie

        if let traffic = fetchInbounds(config: config, cookie: cookie) {
            updateTraffic(config: config, traffic: traffic)
        } else {
            updateError(config: config, error: "获取数据失败")
        }
    }

    /// 登录 3X-UI 面板
    private func login(config: VPSConfig) -> String? {
        let url = URL(string: "\(config.baseURL)/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "username=\(config.username)&password=\(config.password)".data(using: .utf8)
        request.timeoutInterval = 10

        let session = createInsecureSession()
        let semaphore = DispatchSemaphore(value: 0)

        var responseCookie: String?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else { return }

            // 检查登录是否成功
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success {
                // 提取 Set-Cookie
                if let cookies = httpResponse.allHeaderFields["Set-Cookie"] as? String {
                    responseCookie = cookies.components(separatedBy: ";").first
                }
            }
        }
        task.resume()
        semaphore.wait()

        return responseCookie
    }

    /// 获取 inbound 列表（含流量数据）
    private func fetchInbounds(config: VPSConfig, cookie: String) -> [InboundData]? {
        let url = URL(string: "\(config.baseURL)/panel/api/inbounds/list")!
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10

        let session = createInsecureSession()
        let semaphore = DispatchSemaphore(value: 0)

        var result: [InboundData]?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else { return }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success,
               let objs = json["obj"] as? [[String: Any]] {
                result = objs.compactMap { InboundData(from: $0) }
            }
        }
        task.resume()
        semaphore.wait()

        return result
    }

    /// 创建忽略自签证书的 URLSession
    private func createInsecureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: InsecureDelegate(), delegateQueue: nil)
    }

    // MARK: - 数据更新

    private func updateTraffic(config: VPSConfig, traffic: [InboundData]) {
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

    private func updateError(config: VPSConfig, error: String) {
        DispatchQueue.main.async {
            if let idx = self.vpsList.firstIndex(where: { $0.id == config.id }) {
                self.vpsList[idx].error = error
                self.vpsList[idx].lastUpdated = Date()
            } else {
                self.vpsList.append(VPSTraffic(
                    id: config.id, name: config.name,
                    upload: 0, download: 0, total: 0, totalLimit: 0,
                    protocol_: "", port: 0, clients: [],
                    lastUpdated: Date(), isOnline: false, error: error
                ))
            }
        }
    }

    // MARK: - JSON 解析

    private struct InboundData {
        let up: UInt64
        let down: UInt64
        let allTime: UInt64
        let total: UInt64
        let protocol_: String
        let port: Int
        let clients: [ClientData]

        init?(from dict: [String: Any]) {
            guard let up = dict["up"] as? UInt64 ?? (dict["up"] as? Int).map({ UInt64($0) }),
                  let down = dict["down"] as? UInt64 ?? (dict["down"] as? Int).map({ UInt64($0) }) else { return nil }
            self.up = up
            self.down = down
            self.allTime = (dict["allTime"] as? UInt64) ?? (dict["allTime"] as? Int).map({ UInt64($0) }) ?? (up + down)
            self.total = (dict["total"] as? UInt64) ?? (dict["total"] as? Int).map({ UInt64($0) }) ?? 0
            self.protocol_ = dict["protocol"] as? String ?? ""
            self.port = dict["port"] as? Int ?? 0

            if let stats = dict["clientStats"] as? [[String: Any]] {
                self.clients = stats.compactMap { ClientData(from: $0) }
            } else {
                self.clients = []
            }
        }
    }

    private struct ClientData {
        let email: String
        let up: UInt64
        let down: UInt64
        let allTime: UInt64
        let lastOnline: Int64

        init?(from dict: [String: Any]) {
            guard let email = dict["email"] as? String else { return nil }
            self.email = email
            self.up = (dict["up"] as? UInt64) ?? (dict["up"] as? Int).map({ UInt64($0) }) ?? 0
            self.down = (dict["down"] as? UInt64) ?? (dict["down"] as? Int).map({ UInt64($0) }) ?? 0
            self.allTime = (dict["allTime"] as? UInt64) ?? (dict["allTime"] as? Int).map({ UInt64($0) }) ?? 0
            self.lastOnline = (dict["lastOnline"] as? Int64) ?? (dict["lastOnline"] as? Int).map({ Int64($0) }) ?? 0
        }
    }
}

// MARK: - 忽略自签证书

private class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
