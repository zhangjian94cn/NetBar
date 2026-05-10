import Foundation
import Network
import SystemConfiguration

/// 代理/VPN 检测器 — 多策略综合判断
class ProxyDetector: ObservableObject, MonitorProtocol {

    enum ProxyStatus: Equatable {
        case direct
        case systemProxy(String)
        case vpn(String)
        case systemProxyAndVPN(String, String)

        var isProxied: Bool {
            self != .direct
        }

        var isSystemProxyEnabled: Bool {
            switch self {
            case .systemProxy, .systemProxyAndVPN:
                return true
            case .direct, .vpn:
                return false
            }
        }

        var isVPNActive: Bool {
            switch self {
            case .vpn, .systemProxyAndVPN:
                return true
            case .direct, .systemProxy:
                return false
            }
        }

        var headerText: String {
            switch self {
            case .direct:
                return L10n.Proxy.systemDirect
            case .systemProxy, .systemProxyAndVPN:
                if case .systemProxyAndVPN = self {
                    return L10n.Proxy.systemProxyAndTUN
                }
                return L10n.Proxy.systemProxyOn
            case .vpn:
                return L10n.Proxy.tunActive
            }
        }

        var displayText: String {
            switch self {
            case .direct:
                return "直连"
            case .systemProxy(let type):
                return "系统代理 (\(type))"
            case .vpn(let type):
                return "TUN 接管 (\(type))"
            case .systemProxyAndVPN(let proxyType, let vpnType):
                return "系统代理 + TUN 接管 (\(proxyType) + \(vpnType))"
            }
        }

        var emoji: String {
            switch self {
            case .direct: return "🟢"
            case .systemProxy: return "🟡"
            case .vpn: return "🔵"
            case .systemProxyAndVPN: return "🟣"
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
        var detectedSystemProxies: [String] = []
        var detailInfo: [String] = []

        // --- 策略 1: 检查系统代理配置 ---
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {

            // HTTP 代理
            if isProxyEnabled(proxySettings, key: kCFNetworkProxiesHTTPEnable as String) {
                let host = proxySettings[kCFNetworkProxiesHTTPProxy as String] as? String ?? "unknown"
                let port = proxySettings[kCFNetworkProxiesHTTPPort as String] as? Int ?? 0
                detectedSystemProxies.append("HTTP")
                detailInfo.append("HTTP 代理: \(host):\(port)")
            }

            // HTTPS 代理
            if isProxyEnabled(proxySettings, key: kCFNetworkProxiesHTTPSEnable as String) {
                let host = proxySettings[kCFNetworkProxiesHTTPSProxy as String] as? String ?? "unknown"
                let port = proxySettings[kCFNetworkProxiesHTTPSPort as String] as? Int ?? 0
                detectedSystemProxies.append("HTTPS")
                detailInfo.append("HTTPS 代理: \(host):\(port)")
            }

            // SOCKS 代理
            if isProxyEnabled(proxySettings, key: kCFNetworkProxiesSOCKSEnable as String) {
                let host = proxySettings[kCFNetworkProxiesSOCKSProxy as String] as? String ?? "unknown"
                let port = proxySettings[kCFNetworkProxiesSOCKSPort as String] as? Int ?? 0
                detectedSystemProxies.append("SOCKS")
                detailInfo.append("SOCKS 代理: \(host):\(port)")
            }

            // PAC 自动配置
            if isProxyEnabled(proxySettings, key: kCFNetworkProxiesProxyAutoConfigEnable as String) {
                let pacURL = proxySettings[kCFNetworkProxiesProxyAutoConfigURLString as String] as? String ?? ""
                detectedSystemProxies.append("PAC")
                detailInfo.append("PAC: \(pacURL)")
            }
        }

        // --- 策略 2: 检查是否有默认/大网段路由被 TUN 接管 ---
        let tunnelRoutes: [String]
        if DistributionFlavor.current.supportsAdvancedProxyDetection {
            tunnelRoutes = TunnelRouteDetector.activeTunnelRouteDescriptions()
            for route in tunnelRoutes {
                detailInfo.append("TUN 路由: \(route)")
            }
        } else {
            tunnelRoutes = []
        }

        // --- 更新状态 ---
        DispatchQueue.main.async {
            self.details = detailInfo

            if detectedSystemProxies.isEmpty && tunnelRoutes.isEmpty {
                self.status = .direct
            } else if detectedSystemProxies.isEmpty {
                self.status = .vpn(tunnelRoutes.joined(separator: ", "))
            } else if tunnelRoutes.isEmpty {
                self.status = .systemProxy(detectedSystemProxies.joined(separator: " + "))
            } else {
                self.status = .systemProxyAndVPN(
                    detectedSystemProxies.joined(separator: " + "),
                    tunnelRoutes.joined(separator: ", ")
                )
            }
        }
    }

    private func isProxyEnabled(_ settings: [String: Any], key: String) -> Bool {
        if let enabled = settings[key] as? Int {
            return enabled == 1
        }
        if let enabled = settings[key] as? Bool {
            return enabled
        }
        if let enabled = settings[key] as? NSNumber {
            return enabled.intValue == 1
        }
        return false
    }

}
