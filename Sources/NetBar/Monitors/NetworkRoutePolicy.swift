import Foundation

enum NetworkRoutePreference: String, Codable, Equatable {
    case miniPreferred
    case localWiFi

    var displayName: String {
        switch self {
        case .miniPreferred: return "Mac mini 优先"
        case .localWiFi: return "Wi-Fi 优先"
        }
    }
}

struct RouteSafetyHelperStatus: Codable, Equatable {
    let protocolVersion: Int
    let mode: String
    let wifiService: String
    let wifiDevice: String
    let miniService: String
    let pendingTransaction: Bool
    let pendingKind: String?
    let pendingTarget: String
    let wifiDNSMode: String?
    let wifiDNSMiniDependent: Bool?
    let wifiDNSLegacyMiniResolverPresent: Bool?
    let managementAddressReady: Bool?
    let bridgeUsesDHCP: Bool?

    init(
        protocolVersion: Int,
        mode: String,
        wifiService: String,
        wifiDevice: String,
        miniService: String,
        pendingTransaction: Bool,
        pendingKind: String?,
        pendingTarget: String,
        wifiDNSMode: String?,
        wifiDNSMiniDependent: Bool?,
        wifiDNSLegacyMiniResolverPresent: Bool? = nil,
        managementAddressReady: Bool?,
        bridgeUsesDHCP: Bool?
    ) {
        self.protocolVersion = protocolVersion
        self.mode = mode
        self.wifiService = wifiService
        self.wifiDevice = wifiDevice
        self.miniService = miniService
        self.pendingTransaction = pendingTransaction
        self.pendingKind = pendingKind
        self.pendingTarget = pendingTarget
        self.wifiDNSMode = wifiDNSMode
        self.wifiDNSMiniDependent = wifiDNSMiniDependent
        self.wifiDNSLegacyMiniResolverPresent = wifiDNSLegacyMiniResolverPresent
        self.managementAddressReady = managementAddressReady
        self.bridgeUsesDHCP = bridgeUsesDHCP
    }
}

protocol RouteSafetyControlling {
    func status() -> RouteSafetyHelperStatus?
    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult
    func repairWiFiDNS() -> NetworkModeCommandResult
    func removeLegacyMiniDNS() -> NetworkModeCommandResult
    func ensureManagementAlias() -> NetworkModeCommandResult
    func commit() -> NetworkModeCommandResult
    func rollback() -> NetworkModeCommandResult
    func openInstaller() -> NetworkModeCommandResult
}

extension RouteSafetyControlling {
    func removeLegacyMiniDNS() -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "旧 Mini DNS 清理不可用")
    }

    func ensureManagementAlias() -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "管理别名 Helper 不可用")
    }
}

#if APP_STORE
final class LiveRouteSafetyController: RouteSafetyControlling {
    func status() -> RouteSafetyHelperStatus? { nil }
    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "App Store Lite 不支持自动路由")
    }
    func repairWiFiDNS() -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "App Store Lite 不支持 DNS 修复")
    }
    func removeLegacyMiniDNS() -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "App Store Lite 不支持 DNS 清理")
    }
    func ensureManagementAlias() -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "App Store Lite 不支持管理别名恢复")
    }
    func commit() -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: "App Store Lite 不支持自动路由")
    }
    func rollback() -> NetworkModeCommandResult {
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
              status.protocolVersion == 5 else {
            return nil
        }
        return status
    }

    func apply(_ mode: NetworkRouteMode) -> NetworkModeCommandResult {
        runHelper(mode == .macMiniGateway ? "prefer-mini" : "prefer-wifi")
    }

    func repairWiFiDNS() -> NetworkModeCommandResult { runHelper("repair-wifi-dns") }

    func removeLegacyMiniDNS() -> NetworkModeCommandResult { runHelper("remove-legacy-mini-dns") }

    func ensureManagementAlias() -> NetworkModeCommandResult { runHelper("ensure-management-alias") }

    func commit() -> NetworkModeCommandResult { runHelper("commit") }

    func rollback() -> NetworkModeCommandResult { runHelper("rollback") }

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
    var fallbackStartedAt: Date?
    var lastSlowProbeAt: Date?
    var lastClashRecoveryAt: Date?
    var lastAutomaticReturnAt: Date?
    var phase: NetworkFailoverPhase

    init(
        preference: NetworkRoutePreference,
        readySince: Date? = nil,
        consecutiveFailures: Int = 0,
        automaticFallbacks: [Date] = [],
        circuitBreakerUntil: Date? = nil,
        fallbackStartedAt: Date? = nil,
        lastSlowProbeAt: Date? = nil,
        lastClashRecoveryAt: Date? = nil,
        lastAutomaticReturnAt: Date? = nil,
        phase: NetworkFailoverPhase? = nil
    ) {
        self.preference = preference
        self.readySince = readySince
        self.consecutiveFailures = consecutiveFailures
        self.automaticFallbacks = automaticFallbacks
        self.circuitBreakerUntil = circuitBreakerUntil
        self.fallbackStartedAt = fallbackStartedAt
        self.lastSlowProbeAt = lastSlowProbeAt
        self.lastClashRecoveryAt = lastClashRecoveryAt
        self.lastAutomaticReturnAt = lastAutomaticReturnAt
        self.phase = phase ?? (preference == .miniPreferred ? .miniActive : .manualWiFi)
    }

    mutating func recordHealthy(at now: Date) {
        consecutiveFailures = 0
        if readySince == nil { readySince = now }
    }

    mutating func recordFailure() {
        readySince = nil
        consecutiveFailures += 1
    }

    mutating func recordAutomaticFallback(at now: Date) {
        guard let lastAutomaticReturnAt,
              now.timeIntervalSince(lastAutomaticReturnAt) <= 600 else { return }
        self.lastAutomaticReturnAt = nil
        automaticFallbacks = automaticFallbacks.filter { now.timeIntervalSince($0) <= 600 }
        automaticFallbacks.append(now)
        if automaticFallbacks.count >= 2 {
            circuitBreakerUntil = now.addingTimeInterval(600)
            phase = .routeFlapping
        }
    }

    mutating func recordAutomaticReturn(at now: Date) {
        lastAutomaticReturnAt = now
    }

    mutating func recordFailedAutomaticReturn(at now: Date) {
        readySince = nil
        lastAutomaticReturnAt = nil
        automaticFallbacks = automaticFallbacks.filter { now.timeIntervalSince($0) <= 600 }
        automaticFallbacks.append(now)
        if automaticFallbacks.count >= 2 {
            circuitBreakerUntil = now.addingTimeInterval(600)
            phase = .routeFlapping
        }
    }

    mutating func beginWiFiFallback(at now: Date) {
        if fallbackStartedAt == nil {
            fallbackStartedAt = now
            readySince = nil
        }
        if phase != .routeFlapping {
            phase = fallbackDuration(at: now) >= 300 ? .stableWiFiFallback : .temporaryWiFi
        }
    }

    mutating func markMiniActive() {
        fallbackStartedAt = nil
        lastSlowProbeAt = nil
        consecutiveFailures = 0
        readySince = nil
        phase = .miniActive
    }

    mutating func refreshFallbackPhase(at now: Date) {
        guard fallbackStartedAt != nil, phase != .routeFlapping else { return }
        phase = fallbackDuration(at: now) >= 300 ? .stableWiFiFallback : .temporaryWiFi
    }

    func fallbackDuration(at now: Date) -> TimeInterval {
        fallbackStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    mutating func shouldRunSlowFallbackProbe(at now: Date) -> Bool {
        refreshFallbackPhase(at: now)
        guard phase == .stableWiFiFallback else { return true }
        if let lastSlowProbeAt, now.timeIntervalSince(lastSlowProbeAt) < 60 { return false }
        lastSlowProbeAt = now
        return true
    }

    func canRecoverClash(at now: Date) -> Bool {
        guard let lastClashRecoveryAt else { return true }
        return now.timeIntervalSince(lastClashRecoveryAt) >= 60
    }

    mutating func recordClashRecovery(at now: Date) {
        lastClashRecoveryAt = now
    }

    mutating func clearExpiredCircuitBreaker(at now: Date) {
        if let until = circuitBreakerUntil, until <= now {
            circuitBreakerUntil = nil
            automaticFallbacks.removeAll()
            refreshFallbackPhase(at: now)
        }
    }

    func stableDuration(at now: Date) -> TimeInterval {
        readySince.map { now.timeIntervalSince($0) } ?? 0
    }
}
