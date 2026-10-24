import Foundation
import Combine

/// 统一管理所有监控服务的生命周期
/// 将服务创建、关联、启动/停止逻辑从 AppDelegate 中解耦
class MonitorCoordinator {

    let settingsDraft = SettingsDraft()
    var onSettingsOpened: (() -> Void)?
    private var visibleConsumers = VisibleDataConsumers()
    private var subscriptions = Set<AnyCancellable>()

    func openSettings() {
        SettingsWindowController.shared.show(coordinator: self)
        onSettingsOpened?()
    }
    func refreshVisibleFacts() {
        networkInfoProvider.refresh()
        if DistributionFlavor.current == .directFull { networkModeController.refresh(); clashNetworkModeController.refresh() }
    }
    func setVisibleConsumer(_ id: String, visible: Bool) {
        visibleConsumers.set(id, visible: visible)
        processTrafficMonitor.setDetailVisible(visibleConsumers.needsDetails)
    }

    let networkMonitor = NetworkMonitor()
    let proxyDetector = ProxyDetector()
    let processTrafficMonitor = ProcessTrafficMonitor()
    let networkInfoProvider = NetworkInfoProvider()
    let egressIPMonitor = EgressIPMonitor()
    let appIconResolver = AppIconResolver()
    let trafficStore = TrafficStore()
    let vpsTrafficMonitor = VPSTrafficMonitor()
    let companyVPNDiagnosticMonitor = CompanyVPNDiagnosticMonitor()
    private let egressIdentityRefreshScheduler = DebouncedRefreshScheduler(delay: 3)
    lazy var clashNetworkModeController = ClashNetworkModeController()
    lazy var networkModeController = NetworkModeController(
        onNetworkChanged: { [weak self] in
            self?.refreshAfterNetworkModeChange()
        }
    )

    /// 所有遵循 MonitorProtocol 的服务（按启动顺序）
    private var allMonitors: [MonitorProtocol] {
        var monitors: [MonitorProtocol] = [networkMonitor, networkInfoProvider, egressIPMonitor, vpsTrafficMonitor]
        if DistributionFlavor.current.supportsAdvancedProxyDetection {
            monitors.insert(proxyDetector, at: 1)
        }
        if DistributionFlavor.current.supportsProcessTraffic {
            monitors.insert(processTrafficMonitor, at: 2)
            if !Self.isVisualCaptureRun { monitors.insert(trafficStore, at: 4) }
        }
        if DistributionFlavor.current == .directFull {
            monitors.append(companyVPNDiagnosticMonitor)
        }
        return monitors
    }

    /// 启动所有监控服务
    func startAll() {
        // 关联持久化存储（必须在 start 之前）
        if DistributionFlavor.current.supportsProcessTraffic, !Self.isVisualCaptureRun {
            processTrafficMonitor.trafficStore = trafficStore
        }

        networkInfoProvider.$wifiSSID.removeDuplicates().dropFirst().sink { [weak self] _ in self?.identityChanged() }.store(in: &subscriptions)
        networkInfoProvider.$localIP.removeDuplicates().dropFirst().sink { [weak self] _ in self?.identityChanged() }.store(in: &subscriptions)
        proxyDetector.$status.removeDuplicates().dropFirst().sink { [weak self] _ in self?.identityChanged() }.store(in: &subscriptions)
        for monitor in allMonitors {
            monitor.start()
        }
        if DistributionFlavor.current.supportsNetworkModeSwitch, !Self.isVisualCaptureRun {
            networkModeController.startPolicyMonitoring()
        }
    }

    /// Visual QA captures render the panel from live facts but must never drive
    /// the policy state machine: the capture build runs alongside the installed
    /// app, and two policy owners competing for route transactions would fight
    /// over the machine's real network.
    static var isVisualCaptureRun: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["NETBAR_CAPTURE_POPOVER_PATH"] != nil
        #else
        return false
        #endif
    }

    private func identityChanged() {
        clashNetworkModeController.invalidateProbe()
        scheduleEgressIPRefreshAfterIdentityChange()
    }

    /// 停止所有监控服务
    func stopAll() {
        subscriptions.removeAll()
        egressIdentityRefreshScheduler.cancel()
        networkModeController.stopPolicyMonitoring()
        for monitor in allMonitors {
            monitor.stop()
        }
    }

    /// 应用新的采样间隔到正在运行的实时监控器。
    func applyRefreshInterval(_ interval: TimeInterval) {
        networkMonitor.restart(interval: interval)
        if DistributionFlavor.current.supportsProcessTraffic {
            processTrafficMonitor.restart(interval: interval)
        }
    }

    /// 重新读取 VPS 设置并立即刷新，不需要重启应用。
    func reloadVPSConfigsAndRefresh() {
        vpsTrafficMonitor.reloadConfigs()
    }

    /// 应用出口 IP 检测设置并立即刷新。
    func reloadIPCheckSettingsAndRefresh() {
        egressIPMonitor.reloadSettingsAndRefresh()
    }

    /// 网络身份变化后延迟刷新出口 IP，避免代理/TUN 刚切换时拿到旧出口。
    func scheduleEgressIPRefreshAfterIdentityChange() {
        guard AppConfig.shared.ipCheckEnabled else { return }
        egressIdentityRefreshScheduler.schedule { [weak self] in
            self?.egressIPMonitor.reloadSettingsAndRefresh()
        }
    }

    private func refreshAfterNetworkModeChange() {
        proxyDetector.checkProxySettings()
        networkInfoProvider.refresh()
        clashNetworkModeController.invalidateProbe()
        clashNetworkModeController.refresh()
        scheduleEgressIPRefreshAfterIdentityChange()
    }
}
