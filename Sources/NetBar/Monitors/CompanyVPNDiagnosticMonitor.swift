import Foundation
import SystemConfiguration

struct CompanyVPNDiagnosticSnapshot: Equatable {
    enum Health: String, Equatable {
        case ready
        case degraded
        case unavailable
        case unknown
    }

    let health: Health
    let aTrustRunning: Bool
    let protectedRouteInterface: String?
    let portalStatus: String
    let portalEndpoint: String?
    let baselineStatus: String
    let overlayMode: String
    let overlayReason: String?
    let recoveryAvailable: Bool
    let recommendation: String?
    let observedAt: Date?

    static let unknown = CompanyVPNDiagnosticSnapshot(
        health: .unknown,
        aTrustRunning: false,
        protectedRouteInterface: nil,
        portalStatus: "待检测",
        portalEndpoint: nil,
        baselineStatus: "待检测",
        overlayMode: "待检测",
        overlayReason: nil,
        recoveryAvailable: false,
        recommendation: nil,
        observedAt: nil
    )
}

/// Read-only adapter for the company-VPN logic owner. NetBar deliberately does
/// not reproduce aTrust/OAVPN verdict rules and never writes Clash, hosts, DNS,
/// or VPN routes. It reads the redacted artifacts produced by dual-vpn-config.
final class CompanyVPNDiagnosticMonitor: ObservableObject, MonitorProtocol {
    @Published private(set) var snapshot: CompanyVPNDiagnosticSnapshot = .unknown
    @Published private(set) var isRunningOwnerDiagnostic = false
    @Published private(set) var isRecoveringCoexistence = false
    @Published private(set) var errorMessage: String?

    private let fileManager: FileManager
    private let environment: [String: String]
    private let queue = DispatchQueue(label: "com.zjah.NetBar.company-vpn-diagnostic", qos: .utility)
    private var timer: Timer?
    private var lastObservedDoubleOff: Bool?
    private var isRunningOverlayDiagnostic = false

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func start() {
        guard DistributionFlavor.current == .directFull else { return }
        refresh()
        inspectExternalOverlayTransition()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.inspectExternalOverlayTransition()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard DistributionFlavor.current == .directFull else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.collectSnapshot()
            DispatchQueue.main.async {
                self.snapshot = snapshot
                self.errorMessage = nil
            }
        }
    }

    func runOwnerDiagnostic() {
        guard DistributionFlavor.current == .directFull,
              !isRunningOwnerDiagnostic,
              !isRunningOverlayDiagnostic else { return }
        let cliPath = environment["NETBAR_DUAL_VPN_CLI_PATH"] ??
            "/Users/zjah/Documents/code/zhangjian-skills/skills/my/infra/local-dev-config/dual-vpn-config/scripts/dual-vpn-cli.mjs"
        guard fileManager.isReadableFile(atPath: cliPath) else {
            errorMessage = "未找到 dual-vpn-config 诊断入口"
            return
        }
        isRunningOwnerDiagnostic = true
        errorMessage = nil
        let endpointOutputPath = endpointArtifactURL.path
        let overlayOutputPath = overlayArtifactURL.path
        queue.async { [weak self] in
            guard let self else { return }
            let endpointResult = Self.run(
                executable: "/usr/bin/env",
                arguments: ["node", cliPath, "diagnose-oavpn-endpoint", "--json-out", endpointOutputPath]
            )
            let overlayResult = Self.run(
                executable: "/usr/bin/env",
                arguments: ["node", cliPath, "diagnose-overlay-transition", "--json-out", overlayOutputPath]
            )
            let next = self.collectSnapshot()
            DispatchQueue.main.async {
                self.isRunningOwnerDiagnostic = false
                self.snapshot = next
                self.errorMessage = endpointResult == 0 && overlayResult == 0
                    ? nil
                    : "公司 VPN 诊断未完成，请查看 dual-vpn-config 输出"
            }
        }
    }

    private func inspectExternalOverlayTransition() {
        guard DistributionFlavor.current == .directFull else { return }
        let proxyEnabled: Bool
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            let keys = [
                kCFNetworkProxiesHTTPEnable as String,
                kCFNetworkProxiesHTTPSEnable as String,
                kCFNetworkProxiesSOCKSEnable as String,
            ]
            proxyEnabled = keys.contains { key in
                (settings[key] as? NSNumber)?.boolValue == true
            }
        } else {
            proxyEnabled = false
        }
        guard let runtime = MihomoClient.runtimeConfiguration() else { return }
        let doubleOff = !proxyEnabled && !runtime.tunEnabled
        guard lastObservedDoubleOff != doubleOff else { return }
        lastObservedDoubleOff = doubleOff
        guard doubleOff, !isRunningOwnerDiagnostic, !isRunningOverlayDiagnostic else { return }
        isRunningOverlayDiagnostic = true
        let cliPath = environment["NETBAR_DUAL_VPN_CLI_PATH"] ??
            "/Users/zjah/Documents/code/zhangjian-skills/skills/my/infra/local-dev-config/dual-vpn-config/scripts/dual-vpn-cli.mjs"
        guard fileManager.isReadableFile(atPath: cliPath) else {
            isRunningOverlayDiagnostic = false
            return
        }
        let outputPath = overlayArtifactURL.path
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(
                executable: "/usr/bin/env",
                arguments: ["node", cliPath, "diagnose-overlay-transition", "--json-out", outputPath]
            )
            let next = self.collectSnapshot()
            DispatchQueue.main.async {
                self.isRunningOverlayDiagnostic = false
                self.snapshot = next
                if result != 0 {
                    self.errorMessage = "外部模式变化诊断未完成"
                }
            }
        }
    }

    #if !APP_STORE
    func requestCoexistenceRecovery() {
        guard DistributionFlavor.current == .directFull,
              !isRecoveringCoexistence,
              !isRunningOwnerDiagnostic else { return }
        let cliPath = environment["NETBAR_DUAL_VPN_CLI_PATH"] ??
            "/Users/zjah/Documents/code/zhangjian-skills/skills/my/infra/local-dev-config/dual-vpn-config/scripts/dual-vpn-cli.mjs"
        guard fileManager.isReadableFile(atPath: cliPath) else {
            errorMessage = "未找到 dual-vpn-config 恢复入口"
            return
        }
        isRecoveringCoexistence = true
        errorMessage = nil
        let artifactDirectory = overlayArtifactURL.deletingLastPathComponent().path
        let backupDirectory = overlayArtifactURL.deletingLastPathComponent()
            .appendingPathComponent("transactions", isDirectory: true).path
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(
                executable: "/usr/bin/env",
                arguments: [
                    "node", cliPath, "recover-coexistence",
                    "--artifacts-dir", artifactDirectory,
                    "--backup-dir", backupDirectory,
                ]
            )
            let next = self.collectSnapshot()
            DispatchQueue.main.async {
                self.isRecoveringCoexistence = false
                self.snapshot = next
                self.errorMessage = result == 0
                    ? nil
                    : "共存模式恢复未提交，已尝试回滚；请查看诊断结果"
            }
        }
    }
    #endif

    func collectSnapshot() -> CompanyVPNDiagnosticSnapshot {
        let processOutput = Self.commandOutput(executable: "/bin/ps", arguments: ["-axo", "comm="])
        let aTrustRunning = processOutput.localizedCaseInsensitiveContains("atrust") ||
            processOutput.localizedCaseInsensitiveContains("sangfor")
        let routeOutput = Self.commandOutput(
            executable: "/sbin/route",
            arguments: ["-n", "get", "172.21.180.176"]
        )
        let routeInterface = routeOutput
            .split(separator: "\n")
            .first(where: { $0.contains("interface:") })?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let endpoint = readJSON(endpointArtifactURL)
        let baseline = readJSON(baselineArtifactURL)
        let overlay = readJSON(overlayArtifactURL)
        let overlayClassification = overlay?["classification"] as? [String: Any] ?? overlay
        let overlayModeValue = overlayClassification?["mode"] as? String ?? "unknown"
        let overlayReasonValue = overlayClassification?["reason"] as? String
        let recoveryAvailable = overlayClassification?["recovery_available"] as? Bool ?? false
        let portalState = endpoint?["status"] as? String ?? "unknown"
        let endpointIPs = endpoint?["verified_endpoint_ips"] as? [String] ?? []
        let endpointIP = endpointIPs.first
        let persistentState = baseline?["persistent_source_state"] as? String
        let clashState = baseline?["clash_state"] as? String
        let proxyState = baseline?["proxy_state"] as? String
        let baselineHealthy = persistentState == "healthy" &&
            !(clashState?.contains("conflicting") ?? false)
        let baselineStatus: String
        if baseline == nil {
            baselineStatus = "待运行 dual-vpn doctor"
        } else if baselineHealthy {
            baselineStatus = "共存基线正常"
        } else {
            let states = [persistentState, clashState, proxyState].compactMap { $0 }
            baselineStatus = states.isEmpty ? "存在配置漂移" : "配置漂移：\(states.joined(separator: " / "))"
        }

        let protectedRouteReady = routeInterface?.hasPrefix("utun") == true
        let portalReady = portalState == "healthy" || portalState == "vantage_divergence"
        let health: CompanyVPNDiagnosticSnapshot.Health
        if aTrustRunning && protectedRouteReady && portalReady && baselineHealthy && overlayReasonValue == nil {
            health = .ready
        } else if aTrustRunning || portalReady || overlayReasonValue != nil {
            health = .degraded
        } else if endpoint != nil || baseline != nil {
            health = .unavailable
        } else {
            health = .unknown
        }

        let observedAt = ((overlay?["observed_at_utc"] as? String) ??
            (endpoint?["observed_at_utc"] as? String)).flatMap(Self.isoDate)
        return CompanyVPNDiagnosticSnapshot(
            health: health,
            aTrustRunning: aTrustRunning,
            protectedRouteInterface: routeInterface,
            portalStatus: Self.portalText(portalState),
            portalEndpoint: endpointIP,
            baselineStatus: baselineStatus,
            overlayMode: Self.overlayModeText(overlayModeValue),
            overlayReason: Self.overlayReasonText(overlayReasonValue),
            recoveryAvailable: recoveryAvailable,
            recommendation: endpoint?["recommendation"] as? String,
            observedAt: observedAt
        )
    }

    private var stateRootURL: URL {
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state", isDirectory: true)
    }

    private var endpointArtifactURL: URL {
        stateRootURL.appendingPathComponent(
            "zhangjian-skills/dual-vpn-config/oavpn-endpoint-diagnostic.json"
        )
    }

    private var baselineArtifactURL: URL {
        stateRootURL.appendingPathComponent(
            "zhangjian-skills/work-cmcc-automation/artifacts/latest-network-state.json"
        )
    }

    private var overlayArtifactURL: URL {
        stateRootURL.appendingPathComponent(
            "zhangjian-skills/dual-vpn-config/overlay-transition-diagnostic.json"
        )
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func portalText(_ state: String) -> String {
        switch state {
        case "healthy": return "入口已验证"
        case "vantage_divergence": return "入口可用 · 解析视角不同"
        case "override_unhealthy": return "临时节点不可用"
        case "unavailable": return "入口不可用"
        default: return "待检测"
        }
    }

    private static func overlayModeText(_ mode: String) -> String {
        switch mode {
        case "coexistence": return "公司 VPN + 外网共存"
        case "tun_only": return "仅 TUN"
        case "system_proxy": return "仅系统代理"
        case "direct": return "直连兜底"
        default: return "待检测"
        }
    }

    private static func overlayReasonText(_ reason: String?) -> String? {
        switch reason {
        case "physicalUnderlayUnavailable": return "物理网络不可用"
        case "dnsResolverUnavailable": return "公共 DNS 不可用"
        case "staleFakeIPWithoutTunRoute": return "Fake-IP 未随 TUN 关闭而收敛"
        case "tunRouteResidual": return "TUN 已关闭但虚拟路由仍残留"
        case "applicationResolverCacheStale": return "应用连接缓存未刷新"
        case "proxyNodeUnavailable": return "代理节点不可用"
        case "companyBypassUnavailable": return "公司流量绕过规则不可用"
        case "proxyRequiredDestination": return "部分目标需要代理"
        case .some(let value): return value
        case .none: return nil
        }
    }

    private static func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func commandOutput(executable: String, arguments: [String]) -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func run(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }
}
