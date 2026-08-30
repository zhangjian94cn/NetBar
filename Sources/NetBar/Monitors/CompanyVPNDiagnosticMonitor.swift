import Foundation

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
    let recommendation: String?
    let observedAt: Date?

    static let unknown = CompanyVPNDiagnosticSnapshot(
        health: .unknown,
        aTrustRunning: false,
        protectedRouteInterface: nil,
        portalStatus: "待检测",
        portalEndpoint: nil,
        baselineStatus: "待检测",
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
    @Published private(set) var errorMessage: String?

    private let fileManager: FileManager
    private let environment: [String: String]
    private let queue = DispatchQueue(label: "com.zjah.NetBar.company-vpn-diagnostic", qos: .utility)
    private var timer: Timer?

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
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
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
        guard DistributionFlavor.current == .directFull, !isRunningOwnerDiagnostic else { return }
        let cliPath = environment["NETBAR_DUAL_VPN_CLI_PATH"] ??
            "/Users/zjah/Documents/code/zhangjian-skills/skills/my/infra/local-dev-config/dual-vpn-config/scripts/dual-vpn-cli.mjs"
        guard fileManager.isReadableFile(atPath: cliPath) else {
            errorMessage = "未找到 dual-vpn-config 诊断入口"
            return
        }
        isRunningOwnerDiagnostic = true
        errorMessage = nil
        let outputPath = endpointArtifactURL.path
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(
                executable: "/usr/bin/env",
                arguments: ["node", cliPath, "diagnose-oavpn-endpoint", "--json-out", outputPath]
            )
            let next = self.collectSnapshot()
            DispatchQueue.main.async {
                self.isRunningOwnerDiagnostic = false
                self.snapshot = next
                self.errorMessage = result == 0 ? nil : "公司 VPN 诊断未完成，请查看 dual-vpn-config 输出"
            }
        }
    }

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
        if aTrustRunning && protectedRouteReady && portalReady && baselineHealthy {
            health = .ready
        } else if aTrustRunning || portalReady {
            health = .degraded
        } else if endpoint != nil || baseline != nil {
            health = .unavailable
        } else {
            health = .unknown
        }

        let observedAt = (endpoint?["observed_at_utc"] as? String).flatMap(Self.isoDate)
        return CompanyVPNDiagnosticSnapshot(
            health: health,
            aTrustRunning: aTrustRunning,
            protectedRouteInterface: routeInterface,
            portalStatus: Self.portalText(portalState),
            portalEndpoint: endpointIP,
            baselineStatus: baselineStatus,
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
