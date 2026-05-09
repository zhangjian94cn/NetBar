import Foundation

/// 统一管理所有监控服务的生命周期
/// 将服务创建、关联、启动/停止逻辑从 AppDelegate 中解耦
class MonitorCoordinator {

    let networkMonitor = NetworkMonitor()
    let proxyDetector = ProxyDetector()
    let processTrafficMonitor = ProcessTrafficMonitor()
    let networkInfoProvider = NetworkInfoProvider()
    let appIconResolver = AppIconResolver()
    let trafficStore = TrafficStore()
    let vpsTrafficMonitor = VPSTrafficMonitor()

    /// 所有遵循 MonitorProtocol 的服务（按启动顺序）
    private var allMonitors: [MonitorProtocol] {
        [networkMonitor, proxyDetector, processTrafficMonitor,
         networkInfoProvider, trafficStore, vpsTrafficMonitor]
    }

    /// 启动所有监控服务
    func startAll() {
        // 关联持久化存储（必须在 start 之前）
        processTrafficMonitor.trafficStore = trafficStore

        for monitor in allMonitors {
            monitor.start()
        }
    }

    /// 停止所有监控服务
    func stopAll() {
        for monitor in allMonitors {
            monitor.stop()
        }
    }
}
