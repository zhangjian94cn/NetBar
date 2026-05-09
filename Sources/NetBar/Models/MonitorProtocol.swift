import Foundation

/// 统一的监控服务生命周期协议
/// 所有 Monitor / Store 类型都 conform 此协议，使 MonitorCoordinator 可以统一管理
protocol MonitorProtocol: AnyObject {
    func start()
    func stop()
}
