import Foundation
import Network
import SystemConfiguration

/// 代理/VPN 检测器 — 多策略综合判断
class ProxyDetector: ObservableObject {

    enum ProxyStatus: Equatable {
        case direct          // 直连
        case proxied(String) // 代理中，附带代理类型描述

        var isProxied: Bool {
            if case .proxied = self { return true }
            return false
        }

        var displayText: String {
            switch self {
            case .direct:
                return "直连"
            case .proxied(let type):
                return "代理中 (\(type))"
            }
        }

        var emoji: String {
            switch self {
            case .direct: return "🟢"
            case .proxied: return "🟡"
            }
        }
    }

    @Published var status: ProxyStatus = .direct
    @Published var details: [String] = []

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.netbar.proxy-monitor")
    private var timer: Timer?

    init() {}

    func start() {
        // 启动 NWPathMonitor
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor?.start(queue: monitorQueue)

        // 定期检查系统代理配置（每 5 秒）
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkProxySettings()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // 立即检查一次
        checkProxySettings()
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func handlePathUpdate(_ path: NWPath) {
        // 检查是否使用了 VPN 类型的接口
        // VPN/代理连接通常表现为 .other 类型的接口
        DispatchQueue.main.async {
            // 触发一次完整检查
            self.checkProxySettings()
        }
    }

    /// 综合检查代理/VPN 状态
    func checkProxySettings() {
        var detectedProxies: [String] = []
        var detailInfo: [String] = []

        // --- 策略 1: 检查系统代理配置 ---
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {

            // HTTP 代理
            if let httpEnabled = proxySettings[kCFNetworkProxiesHTTPEnable as String] as? Int, httpEnabled == 1 {
                let host = proxySettings[kCFNetworkProxiesHTTPProxy as String] as? String ?? "unknown"
                let port = proxySettings[kCFNetworkProxiesHTTPPort as String] as? Int ?? 0
                detectedProxies.append("HTTP")
                detailInfo.append("HTTP 代理: \(host):\(port)")
            }

            // HTTPS 代理
            if let httpsEnabled = proxySettings[kCFNetworkProxiesHTTPSEnable as String] as? Int, httpsEnabled == 1 {
                let host = proxySettings[kCFNetworkProxiesHTTPSProxy as String] as? String ?? "unknown"
                let port = proxySettings[kCFNetworkProxiesHTTPSPort as String] as? Int ?? 0
                detectedProxies.append("HTTPS")
                detailInfo.append("HTTPS 代理: \(host):\(port)")
            }

            // SOCKS 代理
            if let socksEnabled = proxySettings[kCFNetworkProxiesSOCKSEnable as String] as? Int, socksEnabled == 1 {
                let host = proxySettings[kCFNetworkProxiesSOCKSProxy as String] as? String ?? "unknown"
                let port = proxySettings[kCFNetworkProxiesSOCKSPort as String] as? Int ?? 0
                detectedProxies.append("SOCKS")
                detailInfo.append("SOCKS 代理: \(host):\(port)")
            }

            // PAC 自动配置
            if let pacEnabled = proxySettings[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int, pacEnabled == 1 {
                let pacURL = proxySettings[kCFNetworkProxiesProxyAutoConfigURLString as String] as? String ?? ""
                detectedProxies.append("PAC")
                detailInfo.append("PAC: \(pacURL)")
            }
        }

        // --- 策略 2: 检查 VPN 网络接口 ---
        let vpnInterfaces = detectVPNInterfaces()
        if !vpnInterfaces.isEmpty {
            detectedProxies.append("VPN")
            for iface in vpnInterfaces {
                detailInfo.append("VPN 接口: \(iface)")
            }
        }

        // --- 更新状态 ---
        DispatchQueue.main.async {
            self.details = detailInfo
            if detectedProxies.isEmpty {
                self.status = .direct
            } else {
                self.status = .proxied(detectedProxies.joined(separator: " + "))
            }
        }
    }

    /// 检测 VPN 类型的网络接口
    private func detectVPNInterfaces() -> [String] {
        let vpnPrefixes = ["utun", "ipsec", "ppp", "tap", "tun"]
        var vpnInterfaces: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

            if isUp {
                let isVPN = vpnPrefixes.contains { name.hasPrefix($0) }
                if isVPN && !vpnInterfaces.contains(name) {
                    vpnInterfaces.append(name)
                }
            }

            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }

        return vpnInterfaces
    }
}
