import Combine
import Foundation

enum NetworkRouteMode: String, CaseIterable, Equatable {
    case localWiFi
    case macMiniGateway

    var displayName: String {
        switch self {
        case .localWiFi:
            return "本机 Wi-Fi"
        case .macMiniGateway:
            return "经 Mac mini"
        }
    }
}

enum ThunderboltLinkState: Equatable {
    case connected
    case disconnected
    case addressNotProvisioned
    case miniUnreachable
    case unavailable

    var displayName: String {
        switch self {
        case .connected:
            return "雷雳已连接"
        case .disconnected:
            return "雷雳未连接"
        case .addressNotProvisioned:
            return "需要初始化固定链路"
        case .miniUnreachable:
            return "Mac mini 不可达"
        case .unavailable:
            return "未发现雷雳网桥"
        }
    }
}

struct NetworkServiceEntry: Equatable {
    let name: String
    let hardwarePort: String
    let device: String
    let isDisabled: Bool
}

struct NetworkModeSnapshot: Equatable {
    let services: [NetworkServiceEntry]
    let wifiServiceName: String?
    let wifiDevice: String?
    let thunderboltServiceName: String?
    let thunderboltDevice: String?
    let bridgeIPv4: String?
    let miniGateway: String?
    let physicalDefaultInterface: String?
    let linkState: ThunderboltLinkState
    let gatewayState: MacMiniGatewayState

    var serviceNames: [String] {
        services.map(\.name)
    }

    var intendedMode: NetworkRouteMode? {
        guard let wifiServiceName,
              let thunderboltServiceName,
              let wifiIndex = serviceNames.firstIndex(of: wifiServiceName),
              let thunderboltIndex = serviceNames.firstIndex(of: thunderboltServiceName) else {
            return nil
        }
        return wifiIndex < thunderboltIndex ? .localWiFi : .macMiniGateway
    }

    var effectiveMode: NetworkRouteMode? {
        guard let physicalDefaultInterface else { return nil }
        if physicalDefaultInterface == thunderboltDevice {
            return .macMiniGateway
        }
        if physicalDefaultInterface == wifiDevice {
            return .localWiFi
        }
        return nil
    }

    var isConsistent: Bool {
        guard let intendedMode, let effectiveMode else { return false }
        return intendedMode == effectiveMode
    }

    func reorderedServices(for mode: NetworkRouteMode) -> [String]? {
        var names = serviceNames
        guard let wifiServiceName,
              let thunderboltServiceName,
              let wifiIndex = names.firstIndex(of: wifiServiceName),
              let thunderboltIndex = names.firstIndex(of: thunderboltServiceName) else {
            return nil
        }

        let alreadyOrdered: Bool
        switch mode {
        case .localWiFi:
            alreadyOrdered = wifiIndex < thunderboltIndex
        case .macMiniGateway:
            alreadyOrdered = thunderboltIndex < wifiIndex
        }
        guard !alreadyOrdered else { return names }

        names.swapAt(wifiIndex, thunderboltIndex)
        return names
    }

    func verifies(_ mode: NetworkRouteMode) -> Bool {
        guard intendedMode == mode, effectiveMode == mode else { return false }
        if mode == .macMiniGateway {
            return linkState == .connected && gatewayState == .ready
        }
        return true
    }
}

struct NetworkModeCommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }

    var combinedMessage: String {
        [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum NetworkModeSystemError: LocalizedError {
    case commandFailed(String)
    case invalidServiceOrder

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message.isEmpty ? "读取系统网络配置失败" : message
        case .invalidServiceOrder:
            return "无法解析系统网络服务顺序"
        }
    }
}

protocol NetworkModeSystemProviding {
    func readSnapshot() throws -> NetworkModeSnapshot
    func setServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult
}

protocol NetworkModeCommandRunning {
    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult
    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult
    func runPrivilegedNetworkConfiguration(
        serviceName: String,
        configuration: NetworkServiceConfiguration
    ) -> NetworkModeCommandResult
}

extension NetworkModeCommandRunning {
    func runPrivilegedNetworkConfiguration(
        serviceName: String,
        configuration: NetworkServiceConfiguration
    ) -> NetworkModeCommandResult {
        NetworkModeCommandResult(
            exitCode: -1,
            standardOutput: "",
            standardError: "当前命令运行器不支持管理员网络配置"
        )
    }
}

final class DefaultNetworkModeCommandRunner: NetworkModeCommandRunning {
    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return NetworkModeCommandResult(
                exitCode: -1,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return NetworkModeCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        let script = """
        on run argv
            set commandText to "/usr/sbin/networksetup -ordernetworkservices"
            repeat with serviceName in argv
                set commandText to commandText & " " & quoted form of (serviceName as text)
            end repeat
            do shell script commandText with administrator privileges
        end run
        """
        return run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script] + serviceNames
        )
    }

    func runPrivilegedNetworkConfiguration(
        serviceName: String,
        configuration: NetworkServiceConfiguration
    ) -> NetworkModeCommandResult {
        let script = """
        on run argv
            set serviceName to item 1 of argv
            set methodName to item 2 of argv
            if methodName is "manual" then
                set commandText to "/usr/sbin/networksetup -setmanual " & quoted form of serviceName & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv)
            else
                set commandText to "/usr/sbin/networksetup -setdhcp " & quoted form of serviceName
            end if
            do shell script commandText with administrator privileges

            set dnsCount to (item 6 of argv) as integer
            set dnsCommand to "/usr/sbin/networksetup -setdnsservers " & quoted form of serviceName
            if dnsCount is 0 then
                set dnsCommand to dnsCommand & " Empty"
            else
                repeat with indexValue from 1 to dnsCount
                    set dnsCommand to dnsCommand & " " & quoted form of (item (6 + indexValue) of argv)
                end repeat
            end if
            do shell script dnsCommand with administrator privileges
        end run
        """
        let arguments = [
            serviceName,
            configuration.method.rawValue,
            configuration.ipAddress ?? "",
            configuration.subnetMask ?? "",
            configuration.router ?? "0.0.0.0",
            String(configuration.dnsServers.count)
        ] + configuration.dnsServers
        return run(executable: "/usr/bin/osascript", arguments: ["-e", script] + arguments)
    }
}

final class LiveNetworkModeSystemProvider: NetworkModeSystemProviding {
    private let commandRunner: NetworkModeCommandRunning
    private let profile: MacMiniLinkProfile

    init(
        commandRunner: NetworkModeCommandRunning = DefaultNetworkModeCommandRunner(),
        profile: MacMiniLinkProfile = .bundled
    ) {
        self.commandRunner = commandRunner
        self.profile = profile
    }

    func readSnapshot() throws -> NetworkModeSnapshot {
        let orderResult = commandRunner.run(
            executable: "/usr/sbin/networksetup",
            arguments: ["-listnetworkserviceorder"]
        )
        guard orderResult.succeeded else {
            throw NetworkModeSystemError.commandFailed(orderResult.combinedMessage)
        }

        let services = Self.parseServiceOrder(orderResult.standardOutput)
        guard !services.isEmpty else {
            throw NetworkModeSystemError.invalidServiceOrder
        }

        let thunderboltService = services.first { $0.device == "bridge0" }
        let wifiService = services.first { Self.isWiFiHardwarePort($0.hardwarePort) }

        let bridgeResult = commandRunner.run(
            executable: "/sbin/ifconfig",
            arguments: [thunderboltService?.device ?? "bridge0"]
        )
        let bridgeActive = bridgeResult.succeeded && Self.parseInterfaceActive(bridgeResult.standardOutput)
        let bridgeAddresses = bridgeResult.succeeded ? Self.parseInterfaceIPv4s(bridgeResult.standardOutput) : []
        let bridgeIPv4 = bridgeAddresses.contains(profile.localAddress)
            ? profile.localAddress
            : bridgeAddresses.first

        var gateway: String?
        var bridgeConfigurationIsManual = false
        if let thunderboltService {
            let infoResult = commandRunner.run(
                executable: "/usr/sbin/networksetup",
                arguments: ["-getinfo", thunderboltService.name]
            )
            if infoResult.succeeded {
                gateway = Self.parseNetworkInfoValue("Router", from: infoResult.standardOutput)
                bridgeConfigurationIsManual = infoResult.standardOutput.contains("Manual Configuration")
            }
        }

        let routeResult = commandRunner.run(
            executable: "/sbin/route",
            arguments: ["-n", "get", "default"]
        )
        let physicalDefaultInterface = routeResult.succeeded
            ? Self.parseRouteInterface(routeResult.standardOutput)
            : nil

        let miniReachable: Bool
        if bridgeActive,
           bridgeConfigurationIsManual,
           bridgeAddresses.contains(profile.localAddress),
           gateway == profile.gatewayAddress {
            let pingResult = commandRunner.run(
                executable: "/sbin/ping",
                arguments: [
                    "-b", thunderboltService?.device ?? "bridge0",
                    "-S", profile.localAddress,
                    "-c", "1", "-W", "500", profile.gatewayAddress
                ]
            )
            miniReachable = pingResult.succeeded
        } else {
            miniReachable = false
        }

        let linkState: ThunderboltLinkState
        if thunderboltService == nil {
            linkState = .unavailable
        } else if !bridgeActive {
            linkState = .disconnected
        } else if !bridgeConfigurationIsManual ||
                    !bridgeAddresses.contains(profile.localAddress) ||
                    gateway != profile.gatewayAddress {
            linkState = .addressNotProvisioned
        } else if !miniReachable {
            linkState = .miniUnreachable
        } else {
            linkState = .connected
        }

        let gatewayState: MacMiniGatewayState
        if linkState != .connected {
            gatewayState = .unknown
        } else {
            let hasBoundEgress = profile.probeTargets.contains { target in
                commandRunner.run(
                    executable: "/sbin/ping",
                    arguments: [
                        "-b", thunderboltService?.device ?? "bridge0",
                        "-S", profile.localAddress,
                        "-c", "1", "-W", "700", target
                    ]
                ).succeeded
            }
            gatewayState = hasBoundEgress ? .ready : .upstreamUnavailable
        }

        return NetworkModeSnapshot(
            services: services,
            wifiServiceName: wifiService?.name,
            wifiDevice: wifiService?.device,
            thunderboltServiceName: thunderboltService?.name,
            thunderboltDevice: thunderboltService?.device,
            bridgeIPv4: bridgeIPv4,
            miniGateway: profile.gatewayAddress,
            physicalDefaultInterface: physicalDefaultInterface,
            linkState: linkState,
            gatewayState: gatewayState
        )
    }

    func setServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        let directResult = commandRunner.run(
            executable: "/usr/sbin/networksetup",
            arguments: ["-ordernetworkservices"] + serviceNames
        )
        guard !directResult.succeeded, Self.isAuthorizationFailure(directResult) else {
            return directResult
        }
        return commandRunner.runPrivilegedNetworkServiceOrder(serviceNames)
    }

    static func parseServiceOrder(_ output: String) -> [NetworkServiceEntry] {
        let servicePattern = try? NSRegularExpression(pattern: #"^\((\d+)\)\s+(.+)$"#)
        let hardwarePattern = try? NSRegularExpression(
            pattern: #"^\(Hardware Port:\s*(.*),\s*Device:\s*(.*)\)$"#
        )
        var pendingName: String?
        var pendingDisabled = false
        var services: [NetworkServiceEntry] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)

            if let match = servicePattern?.firstMatch(in: line, range: fullRange),
               let nameRange = Range(match.range(at: 2), in: line) {
                var name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
                pendingDisabled = name.hasPrefix("*")
                if pendingDisabled {
                    name.removeFirst()
                    name = name.trimmingCharacters(in: .whitespaces)
                }
                pendingName = name
                continue
            }

            if let match = hardwarePattern?.firstMatch(in: line, range: fullRange),
               let name = pendingName,
               let portRange = Range(match.range(at: 1), in: line),
               let deviceRange = Range(match.range(at: 2), in: line) {
                services.append(
                    NetworkServiceEntry(
                        name: name,
                        hardwarePort: String(line[portRange]).trimmingCharacters(in: .whitespaces),
                        device: String(line[deviceRange]).trimmingCharacters(in: .whitespaces),
                        isDisabled: pendingDisabled
                    )
                )
                pendingName = nil
                pendingDisabled = false
            }
        }
        return services
    }

    static func parseInterfaceActive(_ output: String) -> Bool {
        output.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces) == "status: active"
        }
    }

    static func parseInterfaceIPv4(_ output: String) -> String? {
        parseInterfaceIPv4s(output).first
    }

    static func parseInterfaceIPv4s(_ output: String) -> [String] {
        var addresses: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, parts[0] == "inet" {
                addresses.append(parts[1])
            }
        }
        return addresses
    }

    static func parseNetworkInfoValue(_ key: String, from output: String) -> String? {
        let prefix = "\(key):"
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty || value == "none" ? nil : value
            }
        }
        return nil
    }

    static func parseRouteInterface(_ output: String) -> String? {
        parseNetworkInfoValue("interface", from: output)
    }

    static func isWiFiHardwarePort(_ hardwarePort: String) -> Bool {
        let normalized = hardwarePort
            .lowercased()
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return normalized.contains("wi-fi") || normalized.contains("wifi")
    }

    static func isAuthorizationFailure(_ result: NetworkModeCommandResult) -> Bool {
        let message = result.combinedMessage.lowercased()
        return message.contains("administrator") ||
            message.contains("authorization") ||
            message.contains("not permitted") ||
            message.contains("permission") ||
            message.contains("must be root")
    }
}

enum NetworkModeSwitchOutcomeKind: Equatable {
    case success
    case unchanged
    case failed
    case rolledBack
    case recoveryRequired
}

struct NetworkModeSwitchOutcome {
    let kind: NetworkModeSwitchOutcomeKind
    let snapshot: NetworkModeSnapshot?
    let message: String?

    var succeeded: Bool {
        kind == .success || kind == .unchanged
    }
}

final class NetworkModeSwitchEngine {
    private let provider: NetworkModeSystemProviding
    private let verificationAttempts: Int
    private let verificationInterval: TimeInterval
    private let sleeper: (TimeInterval) -> Void

    init(
        provider: NetworkModeSystemProviding,
        verificationAttempts: Int = 5,
        verificationInterval: TimeInterval = 2,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.provider = provider
        self.verificationAttempts = max(1, verificationAttempts)
        self.verificationInterval = max(0, verificationInterval)
        self.sleeper = sleeper
    }

    func switchMode(to target: NetworkRouteMode) -> NetworkModeSwitchOutcome {
        let initial: NetworkModeSnapshot
        do {
            initial = try provider.readSnapshot()
        } catch {
            return NetworkModeSwitchOutcome(kind: .failed, snapshot: nil, message: error.localizedDescription)
        }

        guard initial.wifiServiceName != nil, initial.thunderboltServiceName != nil,
              let targetOrder = initial.reorderedServices(for: target) else {
            return NetworkModeSwitchOutcome(
                kind: .failed,
                snapshot: initial,
                message: "未同时发现 Wi-Fi 与雷雳网桥服务"
            )
        }

        if target == .macMiniGateway {
            guard initial.linkState == .connected else {
                return NetworkModeSwitchOutcome(
                    kind: .failed,
                    snapshot: initial,
                    message: initial.linkState.displayName
                )
            }
            guard initial.gatewayState == .ready else {
                return NetworkModeSwitchOutcome(
                    kind: .failed,
                    snapshot: initial,
                    message: initial.gatewayState.displayName
                )
            }
        }

        if initial.verifies(target) {
            return NetworkModeSwitchOutcome(kind: .unchanged, snapshot: initial, message: nil)
        }

        let originalOrder = initial.serviceNames
        let commandResult = provider.setServiceOrder(targetOrder)
        guard commandResult.succeeded else {
            return NetworkModeSwitchOutcome(
                kind: .failed,
                snapshot: try? provider.readSnapshot(),
                message: commandResult.combinedMessage.isEmpty ? "切换网络服务顺序失败" : commandResult.combinedMessage
            )
        }

        if let verified = waitForSnapshot(where: { $0.verifies(target) }) {
            return NetworkModeSwitchOutcome(kind: .success, snapshot: verified, message: nil)
        }

        let rollbackResult = provider.setServiceOrder(originalOrder)
        guard rollbackResult.succeeded else {
            return NetworkModeSwitchOutcome(
                kind: .recoveryRequired,
                snapshot: try? provider.readSnapshot(),
                message: "切换验证失败，且自动恢复原服务顺序失败"
            )
        }

        if let restored = waitForSnapshot(where: { $0.serviceNames == originalOrder }) {
            return NetworkModeSwitchOutcome(
                kind: .rolledBack,
                snapshot: restored,
                message: "切换后的默认物理路由未生效，已恢复原服务顺序"
            )
        }

        return NetworkModeSwitchOutcome(
            kind: .recoveryRequired,
            snapshot: try? provider.readSnapshot(),
            message: "自动恢复命令已执行，但无法确认原服务顺序"
        )
    }

    private func waitForSnapshot(
        where predicate: (NetworkModeSnapshot) -> Bool
    ) -> NetworkModeSnapshot? {
        for attempt in 0..<verificationAttempts {
            if let snapshot = try? provider.readSnapshot(), predicate(snapshot) {
                return snapshot
            }
            if attempt < verificationAttempts - 1 {
                sleeper(verificationInterval)
            }
        }
        return nil
    }
}

final class NetworkModeController: ObservableObject {
    @Published private(set) var snapshot: NetworkModeSnapshot?
    @Published private(set) var isSwitching = false
    @Published private(set) var isProvisioning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var requiresManualRecovery = false

    private let provider: NetworkModeSystemProviding
    private let switchEngine: NetworkModeSwitchEngine
    private let provisioner: NetworkLinkProvisioning
    private let workQueue = DispatchQueue(label: "com.zjah.NetBar.network-mode", qos: .utility)
    private let onNetworkChanged: () -> Void
    private var refreshTimer: Timer?

    init(
        provider: NetworkModeSystemProviding = LiveNetworkModeSystemProvider(),
        provisioner: NetworkLinkProvisioning = NetworkLinkProvisioner(),
        onNetworkChanged: @escaping () -> Void = {}
    ) {
        self.provider = provider
        self.switchEngine = NetworkModeSwitchEngine(provider: provider)
        self.provisioner = provisioner
        self.onNetworkChanged = onNetworkChanged
    }

    func beginObserving() {
        refresh()
        guard refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func endObserving() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        guard !isSwitching, !isProvisioning else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.provider.readSnapshot() }
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    if !self.requiresManualRecovery {
                        self.errorMessage = nil
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func switchMode(to target: NetworkRouteMode) {
        guard !isSwitching, !isProvisioning else { return }
        isSwitching = true
        errorMessage = nil
        requiresManualRecovery = false

        workQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.switchEngine.switchMode(to: target)
            DispatchQueue.main.async {
                self.snapshot = outcome.snapshot ?? self.snapshot
                self.errorMessage = outcome.message
                self.requiresManualRecovery = outcome.kind == .recoveryRequired
                self.isSwitching = false

                if outcome.succeeded {
                    Log.network.info("物理网络出口已切换为 \(target.displayName, privacy: .public)")
                    self.onNetworkChanged()
                } else {
                    Log.network.error("物理网络出口切换未完成: \(outcome.message ?? "未知错误", privacy: .public)")
                }
            }
        }
    }

    func initializeFixedLink() {
        guard !isSwitching, !isProvisioning else { return }
        isProvisioning = true
        errorMessage = "正在确保本机 Wi-Fi 为物理出口…"
        requiresManualRecovery = false

        workQueue.async { [weak self] in
            guard let self else { return }
            let originalSnapshot = try? self.provider.readSnapshot()

            let wifiOutcome = self.switchEngine.switchMode(to: .localWiFi)
            guard wifiOutcome.succeeded else {
                DispatchQueue.main.async {
                    self.snapshot = wifiOutcome.snapshot ?? self.snapshot
                    self.errorMessage = wifiOutcome.message ?? "无法先切换到本机 Wi-Fi"
                    self.requiresManualRecovery = wifiOutcome.kind == .recoveryRequired
                    self.isProvisioning = false
                }
                return
            }

            DispatchQueue.main.async {
                self.errorMessage = "请在 Mac mini 终端完成一次管理员授权；随后本机会请求一次授权"
            }

            let outcome = self.provisioner.provision()
            var finalOutcome = outcome
            if !outcome.succeeded,
               let originalSnapshot,
               wifiOutcome.snapshot?.serviceNames != originalSnapshot.serviceNames {
                let orderRollback = self.provider.setServiceOrder(originalSnapshot.serviceNames)
                if !orderRollback.succeeded {
                    finalOutcome = NetworkLinkProvisioningOutcome(
                        kind: .recoveryRequired,
                        message: "\(outcome.message)；恢复原网络服务顺序失败"
                    )
                }
            }
            let refreshedSnapshot = try? self.provider.readSnapshot()
            DispatchQueue.main.async {
                self.snapshot = refreshedSnapshot ?? wifiOutcome.snapshot ?? self.snapshot
                self.errorMessage = finalOutcome.message
                self.requiresManualRecovery = finalOutcome.kind == .recoveryRequired
                self.isProvisioning = false
                if finalOutcome.succeeded {
                    Log.network.info("固定雷雳链路初始化成功")
                    self.onNetworkChanged()
                } else {
                    Log.network.error("固定雷雳链路初始化失败: \(finalOutcome.message, privacy: .public)")
                }
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
