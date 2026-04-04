import Cocoa
import SwiftUI

/// AppDelegate — 应用程序代理，管理生命周期
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    let networkMonitor = NetworkMonitor()
    let proxyDetector = ProxyDetector()
    let processTrafficMonitor = ProcessTrafficMonitor()
    let networkInfoProvider = NetworkInfoProvider()
    let appIconResolver = AppIconResolver()
    let trafficStore = TrafficStore()
    let vpsTrafficMonitor = VPSTrafficMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 关联持久化存储
        processTrafficMonitor.trafficStore = trafficStore

        statusBarController = StatusBarController(
            networkMonitor: networkMonitor,
            proxyDetector: proxyDetector,
            processTrafficMonitor: processTrafficMonitor,
            networkInfoProvider: networkInfoProvider,
            appIconResolver: appIconResolver,
            vpsTrafficMonitor: vpsTrafficMonitor
        )

        networkMonitor.start()
        proxyDetector.start()
        processTrafficMonitor.start()
        networkInfoProvider.start()
        trafficStore.startPeriodicFlush()
        vpsTrafficMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor.stop()
        proxyDetector.stop()
        processTrafficMonitor.stop()
        networkInfoProvider.stop()
        trafficStore.stop()
        vpsTrafficMonitor.stop()
    }
}
