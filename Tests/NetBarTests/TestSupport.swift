import Foundation
import XCTest
@testable import NetBar
import NetworkExecution

// 共享测试基座。此前 waitUntil 有三份逐字节相同的私有副本（默认超时 1/1/2 秒不一），
// isolatedDefaults 有两份，NetworkModeCommandResult 助手有两份且签名不同。副本本身不只是
// 重复——它是替身语义不一致的根因：每个文件各造一套，取消/超时建模就各写各的。

extension XCTestCase {
    /// 轮询直到条件成立。默认取三份副本里最宽松的 2 秒，CI 负载下 1 秒预算是 flake 来源。
    ///
    /// 注意它在谓词首次为真时立即返回、**不进 RunLoop**，因此不能用它来"等待主队列排空"；
    /// 需要断言主队列投递结果时，谓词必须直接检查那个被投递的值。
    func waitUntil(timeout: TimeInterval = 2, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    /// 每次调用返回一个全新的、已清空的 suite，避免用例之间通过 UserDefaults 串味。
    func isolatedDefaults(suite prefix: String = "netbar-tests") -> UserDefaults {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

extension NetworkModeCommandResult {
    static func ok(_ output: String = "") -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failed(_ error: String = "failed") -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: error)
    }

    /// BoundedCommand 在预算耗尽时的形状：exitCode -3，stderr 带 outcome 前缀。
    /// 替身必须能产出它，否则「helper 卡住」这条路径在策略层永远测不到。
    static func timedOut() -> NetworkModeCommandResult {
        .init(exitCode: -3, standardOutput: "", standardError: "timedOut: ")
    }

    /// BoundedCommand 在本轮被取消时的形状：exitCode -2。
    static func cancelled() -> NetworkModeCommandResult {
        .init(exitCode: -2, standardOutput: "", standardError: "cancelled: ")
    }
}

/// 探测结果工厂。此前只存在于 NetworkRoutePolicyTests 的 fileprivate 静态方法里，
/// 因此任何想建模取消的替身都只能写在那一个文件内。
func makeProbeResult(
    interface: String,
    ready: Bool,
    directReady: Bool? = nil
) -> ConnectivityProbeResult {
    ConnectivityProbeResult(
        interfaceName: interface,
        carrierActive: true,
        ipv4Address: interface == "en0" ? "10.0.0.2" : "192.168.2.2",
        gateway: interface == "en0" ? "10.0.0.1" : "192.168.2.1",
        directHTTPSReachable: directReady ?? ready,
        clashControllerReachable: true,
        clashHTTPSReachable: ready,
        systemHTTPSReachable: ready,
        physicalDefaultInterface: interface
    )
}

/// 忠实建模真实执行层：context 一旦被取消，命令就返回失败，探测因此不 ready。
/// 全仓 6 个 ConnectivityProbing 替身里，这是唯一会检查取消的一个——本次的自我取消缺陷
/// 正是藏在没人建模这条语义的地方。
final class CancellationAwareProber: ConnectivityProbing {
    func probe(interfaceName: String) -> ConnectivityProbeResult {
        makeProbeResult(interface: interfaceName, ready: ProbeContext.current?.isCancelled != true)
    }
    func probeLocal(interfaceName: String) -> ConnectivityProbeResult { probe(interfaceName: interfaceName) }
}

/// 预算耗尽时命令返回 timedOut——用于覆盖「helper 卡住」这条策略层从未被测过的路径。
/// RouteSafetyControlling / NetworkModeSystemProviding / NetworkModeCommandRunning 三个协议
/// 此前没有任何替身会产出 timedOut 或 cancelled。
final class BudgetAwareCommandRunner: NetworkModeCommandRunning {
    private let stalling: Set<String>
    private let lock = NSLock()
    private(set) var invocations: [String] = []

    init(timingOutExecutables: Set<String> = []) { self.stalling = timingOutExecutables }

    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        lock.lock(); invocations.append(executable); lock.unlock()
        if ProbeContext.current?.isCancelled == true { return .cancelled() }
        if stalling.contains(executable) { return .timedOut() }
        return .ok()
    }

    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        .failed("privileged path not available in tests")
    }
}
