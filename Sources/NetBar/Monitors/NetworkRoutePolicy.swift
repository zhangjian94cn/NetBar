import Foundation

enum NetworkRoutePreference: String, Codable, Equatable {
    case miniPreferred
    case localWiFi

    var displayName: String {
        switch self {
        case .miniPreferred: return "Mac mini 优先"
        case .localWiFi: return "本机 Wi-Fi"
        }
    }
}

struct RouteSafetyHelperStatus: Codable, Equatable {
    let protocolVersion: Int
    let mode: String
    let wifiService: String
    let wifiDevice: String
    let miniService: String
    let backupAvailable: Bool
}

protocol RouteSafetyControlling {
    func status() -> RouteSafetyHelperStatus?
    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult
    func openInstaller() -> NetworkModeCommandResult
}

#if APP_STORE
final class LiveRouteSafetyController: RouteSafetyControlling {
    func status() -> RouteSafetyHelperStatus? { nil }
    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "App Store Lite 不支持自动路由")
    }
    func openInstaller() -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "App Store Lite 不支持自动路由")
    }
}
#else
final class LiveRouteSafetyController: RouteSafetyControlling {
    static let helperPath = "/Library/PrivilegedHelperTools/com.zjah.NetBarRouteSafetyHelper"
    private let runner: NetworkModeCommandRunning
    private let bundle: Bundle

    init(
        runner: NetworkModeCommandRunning = DefaultNetworkModeCommandRunner(),
        bundle: Bundle = NetBarResourceBundle.current
    ) {
        self.runner = runner
        self.bundle = bundle
    }

    func status() -> RouteSafetyHelperStatus? {
        let result = runHelper("status")
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let status = try? JSONDecoder().decode(RouteSafetyHelperStatus.self, from: data),
              status.protocolVersion == 1 else {
            return nil
        }
        return status
    }

    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult {
        runHelper(mode == .macMiniGateway ? "prefer-mini" : "prefer-wifi")
    }

    func openInstaller() -> NetworkModeCommandResult {
        guard let installer = bundle.url(
            forResource: "install-netbar-route-safety-helper",
            withExtension: "command",
            subdirectory: "RouteSafetyHelper"
        ) else {
            return .init(exitCode: 1, standardOutput: "", standardError: "安装包缺少 Route Safety Helper")
        }
        let chmod = runner.run(executable: "/bin/chmod", arguments: ["0755", installer.path])
        guard chmod.succeeded else { return chmod }
        return runner.run(executable: "/usr/bin/open", arguments: ["-a", "Terminal", installer.path])
    }

    private func runHelper(_ action: String) -> NetworkModeCommandResult {
        runner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", Self.helperPath, action]
        )
    }
}
#endif

struct NetworkRoutePolicyState: Equatable {
    var preference: NetworkRoutePreference
    var readySince: Date?
    var consecutiveFailures = 0
    var automaticFallbacks: [Date] = []
    var circuitBreakerUntil: Date?

    mutating func recordHealthy(at now: Date) {
        consecutiveFailures = 0
        if readySince == nil { readySince = now }
    }

    mutating func recordFailure() {
        readySince = nil
        consecutiveFailures += 1
    }

    mutating func recordAutomaticFallback(at now: Date) {
        automaticFallbacks = automaticFallbacks.filter { now.timeIntervalSince($0) <= 600 }
        automaticFallbacks.append(now)
        if automaticFallbacks.count >= 2 {
            circuitBreakerUntil = now.addingTimeInterval(600)
        }
    }

    mutating func clearExpiredCircuitBreaker(at now: Date) {
        if let until = circuitBreakerUntil, until <= now {
            circuitBreakerUntil = nil
            automaticFallbacks.removeAll()
        }
    }

    func stableDuration(at now: Date) -> TimeInterval {
        readySince.map { now.timeIntervalSince($0) } ?? 0
    }
}
