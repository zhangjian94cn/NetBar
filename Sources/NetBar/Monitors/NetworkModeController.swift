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
    func reportMacMiniEgressFailure() -> Bool
}

extension NetworkModeSystemProviding {
    func readMacMiniHelperStatus() -> MacMiniHelperStatus? { nil }
    func reportMacMiniEgressFailure() -> Bool { false }
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

    func reportMacMiniEgressFailure() -> Bool {
        #if APP_STORE
        return false
        #else
        return commandRunner.run(
            executable: "/usr/bin/ssh",
            arguments: NetworkLinkProvisioner.sshArguments(
                profile: profile,
                host: profile.gatewayAddress,
                remoteArguments: [
                    "/usr/bin/sudo", "-n",
                    NetworkLinkProvisioner.miniHelperPath,
                    "report-egress-failure"
                ]
            )
        ).succeeded
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

    static func parseRouteGateway(_ output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "gateway" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
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
    private struct PhysicalOutletTransition: Equatable {
        let from: NetworkRouteMode
        let to: NetworkRouteMode

        var logDescription: String { "\(from.rawValue)->\(to.rawValue)" }
    }

    private enum MihomoUnderlayRebindResult: Equatable {
        case notNeeded
        case succeeded
        case failed
    }

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
    @Published private(set) var wifiCandidates: [NetworkAccessCandidate] = []
    @Published private(set) var wifiLocationAccess: WiFiLocationAccessState = .notDetermined
    @Published private(set) var failoverPhase: NetworkFailoverPhase
    @Published private(set) var activeCandidateName: String?
    @Published private(set) var lastClashAction: String?

    private let provider: NetworkModeSystemProviding
    private let switchEngine: NetworkModeSwitchEngine
    private let provisioner: NetworkLinkProvisioning
    private let routeSafetyController: RouteSafetyControlling
    private let wifiCandidateController: WiFiCandidateControlling
    private let connectivityProber: ConnectivityProbing
    private let mihomoRecovery: MihomoRouteRecovering
    private let eventLogger: NetworkEventLogging
    private let candidateStore: WiFiCandidatePreferenceStore
    private let networkChangeObserver: NetworkChangeObserver
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let sleeper: (TimeInterval) -> Void
    private let workQueue = DispatchQueue(label: "com.zjah.NetBar.network-mode", qos: .utility)
    private let onNetworkChanged: () -> Void
    private var policyTimer: Timer?
    private var policyCheckInFlight = false
    private var policyCheckPending = false
    private var fallbackFailureMessage: String?
    private var nextWiFiFallbackAttemptAt: Date?
    private var lastLoggedFallbackFailureReason: String?
    private var reportedMiniEgressFailure = false
    private var observedPhysicalOutlet: NetworkRouteMode?
    private var pendingMihomoTransition: PhysicalOutletTransition?
    private var lastMihomoRebindAttemptAt: Date?
    private var knownMiniGuardianAvailable = false
    private var policyState: NetworkRoutePolicyState
    private let preferenceLock = NSLock()
    private var preferenceValue: NetworkRoutePreference
    private static let preferenceKey = "networkRoutePreference"
    private static let guardianAvailabilityKey = "miniGuardianProtocolV3Available"
    private static let fallbackStartedKey = "networkFallbackStartedAt"
    private static let circuitBreakerKey = "networkCircuitBreakerUntil"
    private static let automaticFallbacksKey = "networkAutomaticFallbacks"
    private static let lastAutomaticReturnKey = "networkLastAutomaticReturnAt"

    init(
        provider: NetworkModeSystemProviding = LiveNetworkModeSystemProvider(),
        provisioner: NetworkLinkProvisioning = NetworkLinkProvisioner(),
        routeSafetyController: RouteSafetyControlling = LiveRouteSafetyController(),
        wifiCandidateController: WiFiCandidateControlling = LiveWiFiCandidateController(),
        connectivityProber: ConnectivityProbing = LiveConnectivityProber(),
        mihomoRecovery: MihomoRouteRecovering = LiveMihomoRouteRecovery(),
        eventLogger: NetworkEventLogging = NetworkEventLogger.shared,
        networkChangeObserver: NetworkChangeObserver = NetworkChangeObserver(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        onNetworkChanged: @escaping () -> Void = {}
    ) {
        let storedPreference = userDefaults.string(forKey: Self.preferenceKey)
            .flatMap(NetworkRoutePreference.init(rawValue:)) ?? .miniPreferred
        let guardianKnown = userDefaults.bool(forKey: Self.guardianAvailabilityKey)
        self.provider = provider
        self.switchEngine = NetworkModeSwitchEngine(provider: provider)
        self.provisioner = provisioner
        self.routeSafetyController = routeSafetyController
        self.wifiCandidateController = wifiCandidateController
        self.connectivityProber = connectivityProber
        self.mihomoRecovery = mihomoRecovery
        self.eventLogger = eventLogger
        self.networkChangeObserver = networkChangeObserver
        self.candidateStore = WiFiCandidatePreferenceStore(defaults: userDefaults)
        self.userDefaults = userDefaults
        self.now = now
        self.sleeper = sleeper
        self.onNetworkChanged = onNetworkChanged
        self.routePreference = storedPreference
        self.preferenceValue = storedPreference
        let persistedFallbacks = (userDefaults.array(forKey: Self.automaticFallbacksKey) as? [Double] ?? [])
            .map(Date.init(timeIntervalSince1970:))
        let initialPhase: NetworkFailoverPhase = storedPreference == .localWiFi
            ? .manualWiFi
            : (userDefaults.object(forKey: Self.fallbackStartedKey) != nil ? .temporaryWiFi : .miniActive)
        self.policyState = NetworkRoutePolicyState(
            preference: storedPreference,
            automaticFallbacks: persistedFallbacks,
            circuitBreakerUntil: userDefaults.object(forKey: Self.circuitBreakerKey) as? Date,
            fallbackStartedAt: userDefaults.object(forKey: Self.fallbackStartedKey) as? Date,
            lastAutomaticReturnAt: userDefaults.object(forKey: Self.lastAutomaticReturnKey) as? Date,
            phase: initialPhase
        )
        self.failoverPhase = initialPhase
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
        refreshWiFiCandidates()
        wifiCandidateController.startMonitoring { [weak self] in
            DispatchQueue.main.async {
                self?.refreshWiFiCandidates()
                self?.performPolicyCheck(force: true)
            }
        }
        networkChangeObserver.start { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if event == .physicalLink {
                    Log.network.info("收到物理链路变化事件，立即重新评估出口")
                }
                let reaction = event.reaction(
                    preference: self.routePreference,
                    activeMode: self.snapshot?.effectiveMode
                )
                if let message = reaction.message {
                    self.policyMessage = message
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + reaction.delay) { [weak self] in
                    self?.performPolicyCheck(force: true)
                }
            }
        }
        guard policyTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.performPolicyCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        policyTimer = timer
        performPolicyCheck(force: true)
    }

    func stopPolicyMonitoring() {
        policyTimer?.invalidate()
        policyTimer = nil
        wifiCandidateController.stopMonitoring()
        networkChangeObserver.stop()
    }

    func runPolicyCheckNow() {
        performPolicyCheck(force: true)
    }

    func requestWiFiLocationAccess() {
        wifiCandidateController.requestLocationAccess()
    }

    func refreshWiFiCandidates() {
        workQueue.async { [weak self] in
            guard let self else { return }
            var pinned = self.candidateStore.load()
            var wifi = self.wifiCandidateController.snapshot(pinnedSSIDs: pinned)
            if !self.candidateStore.isConfigured,
               let current = wifi.currentSSID,
               wifi.savedSSIDs.contains(current) {
                pinned = [current]
                self.candidateStore.save(pinned)
                wifi = self.wifiCandidateController.snapshot(pinnedSSIDs: pinned)
                self.eventLogger.record(event: "wifi_whitelist_migrated", detail: "current saved Wi-Fi pinned", candidateSSID: current)
            }
            DispatchQueue.main.async {
                self.wifiCandidates = wifi.candidates
                self.wifiLocationAccess = wifi.locationAccess
                if let current = wifi.candidates.first(where: \.isCurrent) {
                    self.activeCandidateName = current.displayName
                }
            }
        }
    }

    func setWiFiCandidate(_ ssid: String, pinned: Bool) {
        var values = candidateStore.load()
        if pinned {
            if !values.contains(ssid) { values.append(ssid) }
        } else {
            values.removeAll { $0 == ssid }
        }
        candidateStore.save(values)
        eventLogger.record(event: "wifi_whitelist_changed", detail: pinned ? "pinned" : "unpinned", candidateSSID: ssid)
        refreshWiFiCandidates()
    }

    func moveWiFiCandidate(_ ssid: String, offset: Int) {
        var values = candidateStore.load()
        guard let index = values.firstIndex(of: ssid) else { return }
        let destination = index + offset
        guard values.indices.contains(destination) else { return }
        values.swapAt(index, destination)
        candidateStore.save(values)
        refreshWiFiCandidates()
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
            if target == .localWiFi {
                let succeeded = self.fallbackToVerifiedWiFi(at: self.now(), reason: "用户选择 Wi-Fi 优先", automatic: false)
                DispatchQueue.main.async {
                    self.isSwitching = false
                    if !succeeded { self.errorMessage = self.fallbackFailureMessage ?? self.policyMessage ?? "白名单中没有可验证的 Wi-Fi" }
                }
                return
            }

            let previousMode = (try? self.provider.readSnapshot())?.effectiveMode
            let helperResult = self.routeSafetyController.status() != nil
                ? self.routeSafetyController.apply(.macMiniGateway)
                : nil
            var outcome: NetworkModeSwitchOutcome
            if let helperResult {
                let refreshed = try? self.provider.readSnapshot()
                let rebindResult = refreshed.map {
                    self.rebindMihomoUnderlayIfNeeded(
                        snapshot: $0,
                        previousHint: previousMode,
                        at: self.now()
                    )
                }
                let verified = helperResult.succeeded && refreshed?.verifies(.macMiniGateway) == true &&
                    self.verifyDataPlane(
                        interfaceName: refreshed?.thunderboltDevice ?? "bridge0",
                        afterRebind: rebindResult == .succeeded
                    ).routedInternetReady
                outcome = NetworkModeSwitchOutcome(
                    kind: verified ? .success : .failed,
                    snapshot: refreshed,
                    message: verified ? nil : (helperResult.combinedMessage.isEmpty ? "Mac mini 数据面验证失败" : helperResult.combinedMessage)
                )
            } else {
                outcome = self.switchEngine.switchMode(to: target)
                if outcome.succeeded, let refreshed = outcome.snapshot {
                    let rebindResult = self.rebindMihomoUnderlayIfNeeded(
                        snapshot: refreshed,
                        previousHint: previousMode,
                        at: self.now()
                    )
                    let verified = self.verifyDataPlane(
                        interfaceName: refreshed.thunderboltDevice ?? "bridge0",
                        afterRebind: rebindResult == .succeeded
                    ).routedInternetReady
                    if !verified {
                        outcome = NetworkModeSwitchOutcome(
                            kind: .failed,
                            snapshot: refreshed,
                            message: "Mac mini 物理出口已切换，但 Clash/TUN 数据面未收敛"
                        )
                    }
                }
            }
            if !outcome.succeeded {
                _ = self.fallbackToVerifiedWiFi(
                    at: self.now(),
                    reason: "手动切换 Mac mini 验证失败",
                    automatic: false
                )
            }
            DispatchQueue.main.async {
                self.snapshot = outcome.snapshot ?? self.snapshot
                self.errorMessage = outcome.message
                self.requiresManualRecovery = outcome.kind == .recoveryRequired
                self.isSwitching = false

                if outcome.succeeded {
                    self.workQueue.async {
                        self.policyState.markMiniActive()
                        self.persistPolicyState()
                    }
                    self.activeCandidateName = "Mac mini"
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
            self?.policyState.phase = preference == .miniPreferred ? .miniStabilizing : .manualWiFi
            if preference == .localWiFi { self?.policyState.fallbackStartedAt = nil }
            self?.persistPolicyState()
        }
        userDefaults.set(preference.rawValue, forKey: Self.preferenceKey)
        failoverPhase = preference == .miniPreferred ? .miniStabilizing : .manualWiFi
        policyMessage = preference == .miniPreferred ? "优先使用 Mac mini，可用性异常时自动回退 Wi-Fi" : "优先使用 Wi-Fi，雷雳链路保持可访问"
        stabilizationRemaining = nil
    }

    private func performPolicyCheck(force: Bool = false) {
        guard !isSwitching, !isProvisioning else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            if force { self.nextWiFiFallbackAttemptAt = nil }
            if self.policyCheckInFlight {
                self.policyCheckPending = true
                return
            }
            let preference = self.currentPreference()
            if preference == .miniPreferred,
               !force,
               !self.policyState.shouldRunSlowFallbackProbe(at: self.now()) {
                return
            }
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
            _ = self.rebindMihomoUnderlayIfNeeded(snapshot: current, previousHint: nil, at: checkDate)
            guard preference == .miniPreferred else { return }
            self.policyState.clearExpiredCircuitBreaker(at: checkDate)
            self.persistPolicyState()
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
        let miniProbe = connectivityProber.probe(interfaceName: current.thunderboltDevice ?? "bridge0")
        let boundMiniReachable = current.linkState == .connected && current.gatewayState == .ready
        guard miniProbe.directInternetReady || boundMiniReachable else {
            handleUnhealthySnapshot(current, at: checkDate, helperAvailable: helperAvailable)
            return
        }
        if current.effectiveMode == .macMiniGateway {
            guard miniProbe.routedInternetReady else {
                handleUnhealthySnapshot(current, at: checkDate, helperAvailable: helperAvailable)
                return
            }
            var activeSnapshot = current
            if current.intendedMode != .macMiniGateway {
                guard helperAvailable else {
                    publishPolicy(
                        snapshot: current,
                        message: "Mac mini 出口正常 · 需安装自动切换组件以修复服务顺序",
                        remaining: nil,
                        helperAvailable: false,
                        isError: true,
                        activeCandidate: "Mac mini"
                    )
                    return
                }
                let orderResult = routeSafetyController.apply(.macMiniGateway)
                guard orderResult.succeeded,
                      let reconciled = try? provider.readSnapshot(),
                      reconciled.verifies(.macMiniGateway) else {
                    eventLogger.record(event: "mini_service_order_reconcile", detail: "failed", candidateSSID: nil)
                    publishPolicy(
                        snapshot: current,
                        message: "Mac mini 出口正常 · 服务顺序修复失败",
                        remaining: nil,
                        helperAvailable: true,
                        isError: true,
                        activeCandidate: "Mac mini"
                    )
                    return
                }
                activeSnapshot = reconciled
                eventLogger.record(event: "mini_service_order_reconcile", detail: "success", candidateSSID: nil)
            }
            policyState.recordHealthy(at: checkDate)
            reportedMiniEgressFailure = false
            lastLoggedFallbackFailureReason = nil
            let previousPhase = policyState.phase
            policyState.markMiniActive()
            persistPolicyState()
            if previousPhase != .miniActive {
                eventLogger.record(event: "mini_active", detail: "fixed link and routed data plane verified", candidateSSID: nil)
            }
            publishPolicy(snapshot: activeSnapshot, message: "Mac mini 优先 · 当前出口正常", remaining: nil, activeCandidate: "Mac mini")
            return
        }
        policyState.beginWiFiFallback(at: checkDate)
        policyState.recordHealthy(at: checkDate)
        policyState.phase = .miniStabilizing
        persistPolicyState()
        if let until = policyState.circuitBreakerUntil, until > checkDate {
            let seconds = Int(ceil(until.timeIntervalSince(checkDate)))
            policyState.phase = .routeFlapping
            publishPolicy(snapshot: current, message: "Mac mini 上游反复抖动，\(seconds) 秒后重试", remaining: seconds)
            return
        }
        let elapsed = policyState.stableDuration(at: checkDate)
        guard elapsed >= 30 else {
            let remaining = max(0, Int(ceil(30 - elapsed)))
            publishPolicy(snapshot: current, message: "Mac mini 已恢复，稳定 \(remaining) 秒后自动切回", remaining: remaining)
            return
        }
        guard let remote = provider.readMacMiniHelperStatus(),
              remote.gatewayState == .ready,
              remote.guardianIsFresh(at: checkDate) else {
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
        let rebindResult = verified.map {
            rebindMihomoUnderlayIfNeeded(snapshot: $0, previousHint: current.effectiveMode, at: checkDate)
        }
        let finalMiniProbe = verified.map {
            verifyDataPlane(
                interfaceName: $0.thunderboltDevice ?? "bridge0",
                afterRebind: rebindResult == .succeeded
            )
        }
        if let verified, verified.verifies(.macMiniGateway), finalMiniProbe?.routedInternetReady == true {
            policyState.markMiniActive()
            policyState.recordAutomaticReturn(at: checkDate)
            persistPolicyState()
            publishPolicy(snapshot: verified, message: "已自动切回 Mac mini", remaining: nil, helperAvailable: true, activeCandidate: "Mac mini")
            Log.network.info("Mac mini 上游稳定 30 秒，已自动切回雷雳出口")
            eventLogger.record(event: "automatic_return_to_mini", detail: "30-second stability and full data plane verified", candidateSSID: nil)
            DispatchQueue.main.async { [weak self] in self?.onNetworkChanged() }
        } else {
            let restored = fallbackToVerifiedWiFi(at: checkDate, reason: "自动切回验证失败", automatic: true)
            if !restored {
                let refreshed = (try? provider.readSnapshot()) ?? current
                publishPolicy(snapshot: refreshed, message: "自动切回失败，且没有可验证的 Wi-Fi 候选", remaining: nil, helperAvailable: true, isError: true)
            }
            Log.network.error("自动切回 Mac mini 失败，Wi-Fi 恢复=\(restored)")
        }
    }

    private func handleUnhealthySnapshot(
        _ current: NetworkModeSnapshot,
        at checkDate: Date,
        helperAvailable: Bool
    ) {
        policyState.recordFailure()
        var definitiveFailure: Bool
        switch current.linkState {
        case .disconnected, .unavailable, .addressNotProvisioned, .miniUnreachable:
            definitiveFailure = true
        case .connected:
            definitiveFailure = false
        }
        switch current.gatewayState {
        case .carrierDown, .addressRecovering, .sharingRecovering, .sharingForwardingUnavailable,
             .configurationDrift, .recoveryBackoff:
            definitiveFailure = true
        default:
            break
        }

        if !definitiveFailure {
            var consecutiveHTTPSFailures = 0
            for attempt in 0..<3 {
                let probe = connectivityProber.probe(interfaceName: current.thunderboltDevice ?? "bridge0")
                if probe.directInternetReady {
                    policyState.consecutiveFailures = 0
                    if current.effectiveMode == .localWiFi {
                        handleHealthySnapshot(current, at: checkDate, helperAvailable: helperAvailable)
                    } else {
                        publishPolicy(snapshot: current, message: "Mac mini 直连 HTTPS 正常 · 忽略单一探测失败", remaining: nil, activeCandidate: "Mac mini")
                    }
                    return
                }
                consecutiveHTTPSFailures += 1
                if attempt < 2 { sleeper(2) }
            }
            definitiveFailure = consecutiveHTTPSFailures == 3
        }

        guard definitiveFailure else {
            publishPolicy(snapshot: current, message: current.gatewayState.displayName, remaining: nil)
            return
        }

        policyState.beginWiFiFallback(at: checkDate)
        persistPolicyState()

        if current.linkState == .connected,
           current.gatewayState == .boundEgressUnavailable,
           !reportedMiniEgressFailure {
            reportedMiniEgressFailure = true
            let reported = provider.reportMacMiniEgressFailure()
            eventLogger.record(
                event: "mini_downstream_egress_report",
                detail: reported ? "accepted" : "failed",
                candidateSSID: nil
            )
        }

        let reason = current.linkState != .connected
            ? current.linkState.displayName
            : current.gatewayState.displayName
        if current.effectiveMode == .localWiFi,
           current.intendedMode == .localWiFi {
            let wifiProbe = connectivityProber.probe(interfaceName: current.wifiDevice ?? "en0")
            if wifiProbe.routedInternetReady {
                policyState.beginWiFiFallback(at: checkDate)
                persistPolicyState()
                let message: String
                if current.gatewayState == .sharingForwardingUnavailable {
                    message = "Mac mini 上游正常 · 共享转发未就绪；正在恢复 Network Sharing，期间保持 Wi-Fi"
                } else if current.gatewayState == .remoteEvidenceConflict {
                    message = "Mac mini 共享状态证据冲突；重新采样期间保持 Wi-Fi"
                } else if let until = policyState.circuitBreakerUntil, until > checkDate {
                    message = "Wi-Fi 保网 · Mac mini 抖动熔断 \(Int(ceil(until.timeIntervalSince(checkDate)))) 秒"
                } else if policyState.phase == .stableWiFiFallback {
                    message = "Wi-Fi 稳定保网 · Mini 慢速恢复探测"
                } else {
                    message = "Wi-Fi 临时保网 · Mini 积极恢复中"
                }
                publishPolicy(
                    snapshot: current,
                    message: message,
                    remaining: fallbackRemaining(at: checkDate),
                    helperAvailable: helperAvailable,
                    activeCandidate: activeCandidateName
                )
                return
            }
        }
        if let nextWiFiFallbackAttemptAt, nextWiFiFallbackAttemptAt > checkDate {
            let seconds = Int(ceil(nextWiFiFallbackAttemptAt.timeIntervalSince(checkDate)))
            publishPolicy(
                snapshot: current,
                message: "\(reason)；等待 Wi-Fi 或网络变化（\(seconds) 秒）",
                remaining: fallbackRemaining(at: checkDate),
                helperAvailable: helperAvailable,
                isError: true
            )
            return
        }
        if lastLoggedFallbackFailureReason != reason {
            eventLogger.record(event: "wifi_fallback_started", detail: reason, candidateSSID: nil)
            lastLoggedFallbackFailureReason = reason
        }
        let restored = fallbackToVerifiedWiFi(at: checkDate, reason: reason, automatic: true)
        if !restored {
            nextWiFiFallbackAttemptAt = checkDate.addingTimeInterval(60)
            let refreshed = (try? provider.readSnapshot()) ?? current
            publishPolicy(
                snapshot: refreshed,
                message: "\(reason)；白名单中没有可验证的 Wi-Fi",
                remaining: nil,
                helperAvailable: helperAvailable,
                isError: true
            )
        }
    }

    @discardableResult
    private func fallbackToVerifiedWiFi(at checkDate: Date, reason: String, automatic: Bool) -> Bool {
        fallbackFailureMessage = nil
        let pinned = candidateStore.load()
        let wifi = wifiCandidateController.snapshot(pinnedSSIDs: pinned)
        var candidates = wifi.candidates.filter { $0.isPinned && $0.state != .unavailable }
        if candidates.isEmpty,
           wifi.currentSSID == nil,
           connectivityProber.probe(interfaceName: "en0").hasLocalNetwork {
            // Location access can redact the current SSID. Reusing the already-associated
            // interface does not expand the whitelist or attempt any unknown network.
            candidates = [WiFiCandidateSelector.anonymousCurrentCandidate()]
        }
        candidates.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (pinned.firstIndex(of: lhs.displayName) ?? Int.max) < (pinned.firstIndex(of: rhs.displayName) ?? Int.max)
        }
        guard !candidates.isEmpty else {
            fallbackFailureMessage = "白名单中没有当前可见且已保存的 Wi-Fi"
            return false
        }

        for candidate in candidates {
            updateCandidateState(ssid: candidate.displayName, state: .connecting, current: candidate.isCurrent)
            if !candidate.isCurrent {
                switch wifiCandidateController.associate(ssid: candidate.displayName) {
                case .connected:
                    break
                case .authorizationRequired:
                    fallbackFailureMessage = "Wi-Fi 需要手动连接或系统授权"
                    updateCandidateState(ssid: candidate.displayName, state: .authorizationRequired, current: false)
                    continue
                case .unavailable:
                    fallbackFailureMessage = "候选 Wi-Fi 当前不可用"
                    updateCandidateState(ssid: candidate.displayName, state: .unavailable, current: false)
                    continue
                case .failed(let message):
                    fallbackFailureMessage = message.replacingOccurrences(of: candidate.displayName, with: "<candidate>")
                    updateCandidateState(ssid: candidate.displayName, state: .unavailable, current: false)
                    eventLogger.record(event: "wifi_association_failed", detail: message, candidateSSID: candidate.displayName)
                    continue
                }
            }

            var directProbe = connectivityProber.probe(interfaceName: "en0")
            if !directProbe.hasLocalNetwork {
                for _ in 0..<2 {
                    sleeper(1)
                    directProbe = connectivityProber.probe(interfaceName: "en0")
                    if directProbe.hasLocalNetwork { break }
                }
            }
            guard directProbe.hasLocalNetwork else {
                let state: NetworkCandidateState = .localOnly
                fallbackFailureMessage = state.displayName
                updateCandidateState(ssid: candidate.displayName, state: state, current: true)
                eventLogger.record(event: "wifi_candidate_rejected", detail: state.displayName, candidateSSID: candidate.displayName)
                continue
            }

            let current = try? provider.readSnapshot()
            if current?.effectiveMode != .localWiFi || current?.intendedMode != .localWiFi {
                let helperAvailable = routeSafetyController.status() != nil
                let routeResult: NetworkModeCommandResult
                if helperAvailable {
                    routeResult = routeSafetyController.apply(.localWiFi)
                } else if automatic {
                    routeResult = .init(exitCode: 1, standardOutput: "", standardError: "自动切换组件未安装")
                } else {
                    let outcome = switchEngine.switchMode(to: .localWiFi)
                    routeResult = .init(
                        exitCode: outcome.succeeded ? 0 : 1,
                        standardOutput: "",
                        standardError: outcome.message ?? "Wi-Fi 路由切换失败"
                    )
                }
                guard routeResult.succeeded else {
                    fallbackFailureMessage = routeResult.combinedMessage.isEmpty ? "Wi-Fi 路由切换失败" : routeResult.combinedMessage
                    eventLogger.record(event: "wifi_route_switch_failed", detail: routeResult.combinedMessage, candidateSSID: candidate.displayName)
                    continue
                }
            }

            guard let refreshed = (try? provider.readSnapshot()) ?? current,
                  refreshed.effectiveMode == .localWiFi,
                  refreshed.intendedMode == .localWiFi else {
                fallbackFailureMessage = "Wi-Fi 服务顺序已修改，但默认物理出口验证失败"
                eventLogger.record(event: "wifi_route_verification_failed", detail: reason, candidateSSID: candidate.displayName)
                continue
            }

            let rebindResult = rebindMihomoUnderlayIfNeeded(
                snapshot: refreshed,
                previousHint: current?.effectiveMode,
                at: checkDate
            )

            let changedPhysicalOutlet = current?.effectiveMode != .localWiFi
            if automatic {
                policyState.beginWiFiFallback(at: checkDate)
                if changedPhysicalOutlet {
                    policyState.recordAutomaticFallback(at: checkDate)
                }
            } else if currentPreference() == .localWiFi {
                policyState.fallbackStartedAt = nil
                policyState.phase = .manualWiFi
            } else {
                policyState.beginWiFiFallback(at: checkDate)
            }
            persistPolicyState()
            let convergence = convergeClashAfterWiFiSwitch(
                ssid: candidate.displayName,
                initialProbe: directProbe,
                underlayRebound: rebindResult == .succeeded,
                at: checkDate
            )
            let message: String
            if convergence, directProbe.directInternetReady {
                message = "已使用 Wi-Fi 保网 · \(reason)"
            } else if convergence {
                message = "Wi-Fi 已保网 · 直连受限，Clash/TUN 正常"
            } else if directProbe.directInternetReady {
                message = "Wi-Fi 直连正常 · Clash/TUN 未收敛"
            } else {
                message = "Wi-Fi 局域网正常 · 互联网数据面不可用"
            }
            publishPolicy(
                snapshot: refreshed,
                message: message,
                remaining: fallbackRemaining(at: checkDate),
                helperAvailable: routeSafetyController.status() != nil,
                isError: !convergence,
                activeCandidate: candidate.displayName
            )
            let loggedSSID = candidate.id == WiFiCandidateSelector.anonymousCurrentID ? nil : candidate.displayName
            eventLogger.record(event: "wifi_fallback_active", detail: message, candidateSSID: loggedSSID)
            nextWiFiFallbackAttemptAt = nil
            lastLoggedFallbackFailureReason = nil
            DispatchQueue.main.async { [weak self] in self?.onNetworkChanged() }
            return true
        }
        return false
    }

    private func convergeClashAfterWiFiSwitch(
        ssid: String,
        initialProbe: ConnectivityProbeResult,
        underlayRebound: Bool,
        at checkDate: Date
    ) -> Bool {
        var probe = connectivityProber.probe(interfaceName: "en0")
        if probe.completeInternetReady || probe.routedInternetReady {
            updateCandidateState(ssid: ssid, state: .internetReady, current: true)
            return true
        }
        if underlayRebound {
            for _ in 0..<3 {
                sleeper(2)
                probe = connectivityProber.probe(interfaceName: "en0")
                if probe.completeInternetReady || probe.routedInternetReady {
                    updateCandidateState(ssid: ssid, state: .internetReady, current: true)
                    return true
                }
            }
            updateCandidateState(ssid: ssid, state: .proxyDegraded, current: true)
            return false
        }
        guard initialProbe.directInternetReady,
              probe.clashControllerReachable,
              policyState.canRecoverClash(at: checkDate) else {
            updateCandidateState(ssid: ssid, state: .proxyDegraded, current: true)
            return false
        }

        policyState.recordClashRecovery(at: checkDate)
        persistPolicyState()
        let closed = mihomoRecovery.closeAllConnections()
        DispatchQueue.main.async { [weak self] in
            self?.lastClashAction = closed ? "已清理 Mihomo 旧连接" : "Mihomo 旧连接清理失败"
        }
        eventLogger.record(event: "mihomo_connections_closed", detail: closed ? "success" : "failed", candidateSSID: ssid)
        guard closed else {
            updateCandidateState(ssid: ssid, state: .proxyDegraded, current: true)
            return false
        }
        for _ in 0..<3 {
            sleeper(2)
            probe = connectivityProber.probe(interfaceName: "en0")
            if probe.completeInternetReady {
                updateCandidateState(ssid: ssid, state: .internetReady, current: true)
                return true
            }
        }
        updateCandidateState(ssid: ssid, state: .proxyDegraded, current: true)
        return false
    }

    @discardableResult
    private func rebindMihomoUnderlayIfNeeded(
        snapshot: NetworkModeSnapshot,
        previousHint: NetworkRouteMode?,
        at checkDate: Date
    ) -> MihomoUnderlayRebindResult {
        guard let target = snapshot.effectiveMode else { return .notNeeded }
        if observedPhysicalOutlet == nil {
            observedPhysicalOutlet = previousHint ?? target
        }
        if let previous = observedPhysicalOutlet, previous != target {
            pendingMihomoTransition = PhysicalOutletTransition(from: previous, to: target)
            observedPhysicalOutlet = target
            lastMihomoRebindAttemptAt = nil
        }
        guard let transition = pendingMihomoTransition, transition.to == target else {
            return .notNeeded
        }
        if let lastAttempt = lastMihomoRebindAttemptAt,
           checkDate.timeIntervalSince(lastAttempt) < 5 {
            return .notNeeded
        }
        lastMihomoRebindAttemptAt = checkDate
        guard mihomoRecovery.isControllerAvailable() else {
            eventLogger.record(
                event: "mihomo_underlay_rebind",
                detail: "\(transition.logDescription): controller unavailable",
                candidateSSID: nil
            )
            return .failed
        }

        policyState.recordClashRecovery(at: checkDate)
        persistPolicyState()
        let closed = mihomoRecovery.closeAllConnections()
        DispatchQueue.main.async { [weak self] in
            self?.lastClashAction = closed
                ? "物理出口已变化，Mihomo 连接已自动刷新"
                : "物理出口已变化，Mihomo 连接刷新失败"
        }
        eventLogger.record(
            event: "mihomo_underlay_rebind",
            detail: "\(transition.logDescription): \(closed ? "success" : "failed")",
            candidateSSID: nil
        )
        guard closed else { return .failed }
        pendingMihomoTransition = nil
        lastMihomoRebindAttemptAt = nil
        sleeper(1)
        return .succeeded
    }

    private func verifyDataPlane(
        interfaceName: String,
        afterRebind: Bool
    ) -> ConnectivityProbeResult {
        var probe = connectivityProber.probe(interfaceName: interfaceName)
        guard afterRebind else { return probe }
        for _ in 0..<3 where !probe.routedInternetReady {
            sleeper(2)
            probe = connectivityProber.probe(interfaceName: interfaceName)
        }
        return probe
    }

    private func publishPolicy(
        snapshot: NetworkModeSnapshot,
        message: String,
        remaining: Int?,
        helperAvailable: Bool? = nil,
        isError: Bool = false,
        activeCandidate: String? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = snapshot
            self.policyMessage = message
            self.stabilizationRemaining = remaining
            self.failoverPhase = self.policyState.phase
            if let activeCandidate { self.activeCandidateName = activeCandidate }
            if let helperAvailable { self.automationHelperAvailable = helperAvailable }
            if isError {
                self.errorMessage = message
            } else if !self.requiresManualRecovery {
                self.errorMessage = nil
            }
        }
    }

    private func fallbackRemaining(at date: Date) -> Int? {
        let elapsed = policyState.fallbackDuration(at: date)
        guard elapsed < 300 else { return nil }
        return max(0, Int(ceil(300 - elapsed)))
    }

    private func persistPolicyState() {
        if let date = policyState.fallbackStartedAt {
            userDefaults.set(date, forKey: Self.fallbackStartedKey)
        } else {
            userDefaults.removeObject(forKey: Self.fallbackStartedKey)
        }
        if let date = policyState.circuitBreakerUntil {
            userDefaults.set(date, forKey: Self.circuitBreakerKey)
        } else {
            userDefaults.removeObject(forKey: Self.circuitBreakerKey)
        }
        userDefaults.set(
            policyState.automaticFallbacks.map(\.timeIntervalSince1970),
            forKey: Self.automaticFallbacksKey
        )
        if let date = policyState.lastAutomaticReturnAt {
            userDefaults.set(date, forKey: Self.lastAutomaticReturnKey)
        } else {
            userDefaults.removeObject(forKey: Self.lastAutomaticReturnKey)
        }
        DispatchQueue.main.async { [weak self] in self?.failoverPhase = self?.policyState.phase ?? .miniActive }
    }

    private func updateCandidateState(ssid: String, state: NetworkCandidateState, current: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wifiCandidates = self.wifiCandidates.map { candidate in
                guard candidate.displayName == ssid else {
                    var copy = candidate
                    if current { copy.isCurrent = false }
                    return copy
                }
                var copy = candidate
                copy.state = state
                copy.isCurrent = current
                return copy
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
        wifiCandidateController.stopMonitoring()
        networkChangeObserver.stop()
    }
}
