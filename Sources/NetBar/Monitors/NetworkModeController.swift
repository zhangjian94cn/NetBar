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
    func readMacMiniHelperStatus() -> MacMiniHelperStatus?
}

extension NetworkModeSystemProviding {
    func readMacMiniHelperStatus() -> MacMiniHelperStatus? { nil }
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
        var bridgeDNSIncludesGateway = false
        if let thunderboltService {
            let infoResult = commandRunner.run(
                executable: "/usr/sbin/networksetup",
                arguments: ["-getinfo", thunderboltService.name]
            )
            if infoResult.succeeded {
                gateway = Self.parseNetworkInfoValue("Router", from: infoResult.standardOutput)
                bridgeConfigurationIsManual = infoResult.standardOutput.contains("Manual Configuration")
            }
            let dnsResult = commandRunner.run(
                executable: "/usr/sbin/networksetup",
                arguments: ["-getdnsservers", thunderboltService.name]
            )
            bridgeDNSIncludesGateway = dnsResult.succeeded && dnsResult.standardOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains(profile.gatewayAddress)
        }

        let routeResult = commandRunner.run(
            executable: "/sbin/route",
            arguments: ["-n", "get", "default"]
        )
        var physicalDefaultInterface = routeResult.succeeded
            ? Self.parseRouteInterface(routeResult.standardOutput)
            : nil
        if physicalDefaultInterface?.hasPrefix("utun") == true || physicalDefaultInterface == nil {
            let nwiResult = commandRunner.run(
                executable: "/usr/sbin/scutil",
                arguments: ["--nwi"]
            )
            if nwiResult.succeeded {
                physicalDefaultInterface = Self.parseNWIPrimaryPhysicalInterface(
                    nwiResult.standardOutput,
                    candidates: [wifiService?.device, thunderboltService?.device].compactMap { $0 }
                )
            }
        }

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
                    gateway != profile.gatewayAddress ||
                    !bridgeDNSIncludesGateway {
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
            if hasBoundEgress {
                gatewayState = .ready
            } else if let remoteStatus = readMacMiniHelperStatus() {
                let remoteState = remoteStatus.gatewayState
                gatewayState = (remoteState == .ready || remoteState == .unknown)
                    ? .boundEgressUnavailable
                    : remoteState
            } else {
                gatewayState = .remoteStatusUnavailable
            }
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

    func readMacMiniHelperStatus() -> MacMiniHelperStatus? {
        #if APP_STORE
        return nil
        #else
        let result = commandRunner.run(
            executable: "/usr/bin/ssh",
            arguments: NetworkLinkProvisioner.sshArguments(
                profile: profile,
                host: profile.gatewayAddress,
                remoteArguments: [
                    "/usr/bin/sudo", "-n",
                    NetworkLinkProvisioner.miniHelperPath,
                    "status"
                ]
            )
        )
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let status = try? JSONDecoder().decode(MacMiniHelperStatus.self, from: data),
              status.protocolVersion == NetworkLinkProvisioner.miniHelperProtocolVersion else {
            return nil
        }
        return status
        #endif
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

    static func parseNWIPrimaryPhysicalInterface(
        _ output: String,
        candidates: [String]
    ) -> String? {
        guard let line = output.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Network interfaces:")
        }), let separator = line.firstIndex(of: ":") else {
            return nil
        }
        let interfaces = line[line.index(after: separator)...].split(whereSeparator: { $0.isWhitespace })
        return interfaces.map(String.init).first(where: candidates.contains)
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
    @Published private(set) var routePreference: NetworkRoutePreference
    @Published private(set) var policyMessage: String?
    @Published private(set) var stabilizationRemaining: Int?
    @Published private(set) var automationHelperAvailable = false
    @Published private(set) var miniGuardianAvailable = false

    private let provider: NetworkModeSystemProviding
    private let switchEngine: NetworkModeSwitchEngine
    private let provisioner: NetworkLinkProvisioning
    private let routeSafetyController: RouteSafetyControlling
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let workQueue = DispatchQueue(label: "com.zjah.NetBar.network-mode", qos: .utility)
    private let onNetworkChanged: () -> Void
    private var policyTimer: Timer?
    private var policyCheckInFlight = false
    private var policyCheckPending = false
    private var knownMiniGuardianAvailable = false
    private var policyState: NetworkRoutePolicyState
    private let preferenceLock = NSLock()
    private var preferenceValue: NetworkRoutePreference
    private static let preferenceKey = "networkRoutePreference"
    private static let guardianAvailabilityKey = "miniGuardianProtocolV3Available"

    init(
        provider: NetworkModeSystemProviding = LiveNetworkModeSystemProvider(),
        provisioner: NetworkLinkProvisioning = NetworkLinkProvisioner(),
        routeSafetyController: RouteSafetyControlling = LiveRouteSafetyController(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        onNetworkChanged: @escaping () -> Void = {}
    ) {
        let storedPreference = userDefaults.string(forKey: Self.preferenceKey)
            .flatMap(NetworkRoutePreference.init(rawValue:)) ?? .miniPreferred
        let guardianKnown = userDefaults.bool(forKey: Self.guardianAvailabilityKey)
        self.provider = provider
        self.switchEngine = NetworkModeSwitchEngine(provider: provider)
        self.provisioner = provisioner
        self.routeSafetyController = routeSafetyController
        self.userDefaults = userDefaults
        self.now = now
        self.onNetworkChanged = onNetworkChanged
        self.routePreference = storedPreference
        self.preferenceValue = storedPreference
        self.policyState = NetworkRoutePolicyState(preference: storedPreference)
        self.miniGuardianAvailable = guardianKnown
        self.knownMiniGuardianAvailable = guardianKnown
    }

    func beginObserving() {
        refresh()
    }

    func endObserving() {}

    func startPolicyMonitoring() {
        guard DistributionFlavor.current.supportsNetworkModeSwitch else { return }
        automationHelperAvailable = routeSafetyController.status() != nil
        refresh()
        guard policyTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.performPolicyCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        policyTimer = timer
        performPolicyCheck()
    }

    func stopPolicyMonitoring() {
        policyTimer?.invalidate()
        policyTimer = nil
    }

    func runPolicyCheckNow() {
        performPolicyCheck()
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
        setPreference(target == .macMiniGateway ? .miniPreferred : .localWiFi)

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

    func installAutomationHelper() {
        let result = routeSafetyController.openInstaller()
        if result.succeeded {
            errorMessage = "请在终端完成一次管理员授权；安装后 NetBar 会自动检测"
        } else {
            errorMessage = result.combinedMessage.isEmpty ? "无法打开自动切换组件安装器" : result.combinedMessage
        }
    }

    private func setPreference(_ preference: NetworkRoutePreference) {
        routePreference = preference
        preferenceLock.lock()
        preferenceValue = preference
        preferenceLock.unlock()
        workQueue.async { [weak self] in
            self?.policyState.preference = preference
            self?.policyState.readySince = nil
            self?.policyState.consecutiveFailures = 0
        }
        userDefaults.set(preference.rawValue, forKey: Self.preferenceKey)
        policyMessage = preference == .miniPreferred ? "目标：经 Mac mini" : "目标：本机 Wi-Fi"
        stabilizationRemaining = nil
    }

    private func performPolicyCheck() {
        guard routePreference == .miniPreferred, !isSwitching, !isProvisioning else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.policyCheckInFlight {
                self.policyCheckPending = true
                return
            }
            guard self.currentPreference() == .miniPreferred else { return }
            self.policyCheckInFlight = true
            defer {
                self.policyCheckInFlight = false
                if self.policyCheckPending {
                    self.policyCheckPending = false
                    DispatchQueue.main.async { [weak self] in
                        self?.performPolicyCheck()
                    }
                }
            }
            guard let current = try? self.provider.readSnapshot() else { return }
            let checkDate = self.now()
            self.policyState.clearExpiredCircuitBreaker(at: checkDate)
            let helperAvailable = self.routeSafetyController.status() != nil
            let guardianAvailable = self.knownMiniGuardianAvailable
            DispatchQueue.main.async { [weak self] in
                self?.miniGuardianAvailable = guardianAvailable
            }

            if current.linkState == .connected, current.gatewayState == .ready {
                self.handleHealthySnapshot(current, at: checkDate, helperAvailable: helperAvailable)
            } else {
                self.handleUnhealthySnapshot(current, at: checkDate, helperAvailable: helperAvailable)
            }
        }
    }

    private func handleHealthySnapshot(
        _ current: NetworkModeSnapshot,
        at checkDate: Date,
        helperAvailable: Bool
    ) {
        policyState.recordHealthy(at: checkDate)
        if current.effectiveMode == .macMiniGateway {
            publishPolicy(snapshot: current, message: "Mac mini 优先 · 当前出口正常", remaining: nil)
            return
        }
        if let until = policyState.circuitBreakerUntil, until > checkDate {
            let seconds = Int(ceil(until.timeIntervalSince(checkDate)))
            publishPolicy(snapshot: current, message: "Mac mini 上游反复抖动，\(seconds) 秒后重试", remaining: seconds)
            return
        }
        let elapsed = policyState.stableDuration(at: checkDate)
        guard elapsed >= 30 else {
            let remaining = max(0, Int(ceil(30 - elapsed)))
            publishPolicy(snapshot: current, message: "Mac mini 已恢复，稳定 \(remaining) 秒后自动切回", remaining: remaining)
            return
        }
        guard let remote = provider.readMacMiniHelperStatus(), remote.guardian?.state == .ready else {
            publishPolicy(snapshot: current, message: "等待 Mac mini Guardian 确认共享稳定", remaining: nil)
            return
        }
        recordMiniGuardianAvailability(true)
        DispatchQueue.main.async { [weak self] in
            self?.miniGuardianAvailable = true
        }
        guard helperAvailable else {
            publishPolicy(snapshot: current, message: "Mac mini 已恢复；需安装自动切换组件", remaining: nil, helperAvailable: false)
            return
        }
        guard currentPreference() == .miniPreferred else { return }

        let result = routeSafetyController.apply(.macMiniGateway)
        let verified = result.succeeded ? (try? provider.readSnapshot()) : nil
        if let verified, verified.verifies(.macMiniGateway) {
            policyState.readySince = checkDate
            publishPolicy(snapshot: verified, message: "已自动切回 Mac mini", remaining: nil, helperAvailable: true)
            Log.network.info("Mac mini 上游稳定 30 秒，已自动切回雷雳出口")
            DispatchQueue.main.async { [weak self] in self?.onNetworkChanged() }
        } else {
            policyState.recordAutomaticFallback(at: checkDate)
            let fallbackResult = result.succeeded
                ? routeSafetyController.apply(.localWiFi)
                : result
            let refreshed = (try? provider.readSnapshot()) ?? current
            let fallbackVerified = fallbackResult.succeeded && refreshed.effectiveMode == .localWiFi
            let message: String
            if fallbackVerified {
                message = "自动切回验证失败，已恢复本机 Wi-Fi"
            } else if fallbackResult.combinedMessage.contains("manualRecoveryRequired") {
                message = "自动切回与恢复均失败，需要手动恢复"
            } else {
                message = fallbackResult.combinedMessage.isEmpty
                    ? "自动切回失败，无法确认已恢复本机 Wi-Fi"
                    : fallbackResult.combinedMessage
            }
            publishPolicy(
                snapshot: refreshed,
                message: message,
                remaining: nil,
                helperAvailable: true,
                isError: true
            )
            Log.network.error("自动切回 Mac mini 失败，Wi-Fi 恢复=\(fallbackVerified): \(message, privacy: .public)")
        }
    }

    private func handleUnhealthySnapshot(
        _ current: NetworkModeSnapshot,
        at checkDate: Date,
        helperAvailable: Bool
    ) {
        policyState.recordFailure()
        let definitiveFailure: Bool
        switch current.gatewayState {
        case .carrierDown, .addressRecovering, .sharingRecovering, .configurationDrift, .recoveryBackoff:
            definitiveFailure = true
        default:
            definitiveFailure = false
        }
        let shouldFallback = current.effectiveMode == .macMiniGateway &&
            (definitiveFailure || policyState.consecutiveFailures >= 3)
        guard shouldFallback else {
            publishPolicy(snapshot: current, message: current.gatewayState.displayName, remaining: nil)
            return
        }
        guard helperAvailable else {
            publishPolicy(snapshot: current, message: "\(current.gatewayState.displayName)；需安装自动切换组件", remaining: nil, helperAvailable: false, isError: true)
            return
        }
        let result = routeSafetyController.apply(.localWiFi)
        let refreshed = (try? provider.readSnapshot()) ?? current
        if result.succeeded, refreshed.effectiveMode == .localWiFi {
            policyState.recordAutomaticFallback(at: checkDate)
            publishPolicy(snapshot: refreshed, message: "已恢复本机 Wi-Fi · \(current.gatewayState.displayName)", remaining: nil, helperAvailable: true)
            Log.network.error("Mac mini 上游异常，已自动回退本机 Wi-Fi: \(current.gatewayState.displayName, privacy: .public)")
            DispatchQueue.main.async { [weak self] in self?.onNetworkChanged() }
        } else {
            let message = result.combinedMessage.contains("manualRecoveryRequired")
                ? "自动回退失败，需要手动恢复"
                : (result.combinedMessage.isEmpty ? "自动回退本机 Wi-Fi 失败" : result.combinedMessage)
            publishPolicy(snapshot: refreshed, message: message, remaining: nil, helperAvailable: true, isError: true)
        }
    }

    private func publishPolicy(
        snapshot: NetworkModeSnapshot,
        message: String,
        remaining: Int?,
        helperAvailable: Bool? = nil,
        isError: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = snapshot
            self.policyMessage = message
            self.stabilizationRemaining = remaining
            if let helperAvailable { self.automationHelperAvailable = helperAvailable }
            if isError {
                self.errorMessage = message
            } else if !self.requiresManualRecovery {
                self.errorMessage = nil
            }
        }
    }

    private func currentPreference() -> NetworkRoutePreference {
        preferenceLock.lock()
        defer { preferenceLock.unlock() }
        return preferenceValue
    }

    private func recordMiniGuardianAvailability(_ available: Bool) {
        knownMiniGuardianAvailable = available
        userDefaults.set(available, forKey: Self.guardianAvailabilityKey)
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
            let guardianInstalled = finalOutcome.succeeded && self.provider.readMacMiniHelperStatus()?.guardian != nil
            if guardianInstalled {
                self.recordMiniGuardianAvailability(true)
            }
            DispatchQueue.main.async {
                self.snapshot = refreshedSnapshot ?? wifiOutcome.snapshot ?? self.snapshot
                self.errorMessage = finalOutcome.message
                self.requiresManualRecovery = finalOutcome.kind == .recoveryRequired
                self.isProvisioning = false
                if finalOutcome.succeeded {
                    Log.network.info("固定雷雳链路初始化成功")
                    self.miniGuardianAvailable = guardianInstalled
                    self.onNetworkChanged()
                } else {
                    Log.network.error("固定雷雳链路初始化失败: \(finalOutcome.message, privacy: .public)")
                }
            }
        }
    }

    deinit {
        policyTimer?.invalidate()
    }
}
