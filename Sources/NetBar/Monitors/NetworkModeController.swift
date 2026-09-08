import NetworkExecution
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
    var gatewayState: MacMiniGatewayState
    var physicalLinkActive: Bool? = nil
    var observedAt: Date? = nil

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

extension NetworkModeCommandResult {
    func isSuccessfulConnectivityHTTPResponse(for target: String) -> Bool {
        guard succeeded,
              let status = Int(standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return target.contains("generate_204") ? status == 204 : status == 200
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
    func readLocalSnapshot() throws -> NetworkModeSnapshot
    func qualifySnapshot(_ local: NetworkModeSnapshot) throws -> NetworkModeSnapshot
    func readSnapshot() throws -> NetworkModeSnapshot
    func setServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult
    func readMacMiniHelperStatus() -> MacMiniHelperStatus?
    func reportMacMiniEgressFailure() -> Bool
}

extension NetworkModeSystemProviding {
    func readLocalSnapshot() throws -> NetworkModeSnapshot { try readSnapshot() }
    func qualifySnapshot(_ local: NetworkModeSnapshot) throws -> NetworkModeSnapshot { local }
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
    func runPrivilegedEnsureManagementAlias(address: String, subnetMask: String) -> NetworkModeCommandResult
    func runPrivilegedManagementMigration(
        serviceName: String,
        address: String,
        subnetMask: String,
        dnsServers: [String]
    ) -> NetworkModeCommandResult
    func runPrivilegedRemoveManagementAlias(address: String) -> NetworkModeCommandResult
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

    func runPrivilegedEnsureManagementAlias(address: String, subnetMask: String) -> NetworkModeCommandResult {
        .init(exitCode: -1, standardOutput: "", standardError: "当前命令运行器不支持管理别名配置")
    }

    func runPrivilegedManagementMigration(
        serviceName: String,
        address: String,
        subnetMask: String,
        dnsServers: [String]
    ) -> NetworkModeCommandResult {
        .init(exitCode: -1, standardOutput: "", standardError: "当前命令运行器不支持地址面迁移")
    }

    func runPrivilegedRemoveManagementAlias(address: String) -> NetworkModeCommandResult {
        .init(exitCode: -1, standardOutput: "", standardError: "当前命令运行器不支持移除管理别名")
    }
}

final class DefaultNetworkModeCommandRunner: NetworkModeCommandRunning {
    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        let budget: TimeInterval
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "curl": budget = 4
        case "ssh": budget = 6
        case "sudo": budget = 5
        case "osascript": budget = 120 // explicit, interactive operations only
        default: budget = 2
        }
        let result = BoundedCommand.run(executable, arguments, timeout: budget)
        return .init(exitCode: result.exitCode, standardOutput: result.stdout,
                     standardError: result.outcome == .exited ? result.stderr : "\(result.outcome.rawValue): \(result.stderr)")
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

    func runPrivilegedEnsureManagementAlias(address: String, subnetMask: String) -> NetworkModeCommandResult {
        let script = """
        on run argv
            set commandText to "/sbin/ifconfig bridge0 alias " & quoted form of (item 1 of argv) & " netmask " & quoted form of (item 2 of argv)
            do shell script commandText with administrator privileges
        end run
        """
        return run(executable: "/usr/bin/osascript", arguments: ["-e", script, address, subnetMask])
    }

    func runPrivilegedManagementMigration(
        serviceName: String,
        address: String,
        subnetMask: String,
        dnsServers: [String]
    ) -> NetworkModeCommandResult {
        let script = """
        on run argv
            set serviceName to item 1 of argv
            set managementAddress to item 2 of argv
            set managementMask to item 3 of argv
            set dnsCount to (item 4 of argv) as integer
            do shell script "/usr/sbin/networksetup -setdhcp " & quoted form of serviceName with administrator privileges
            do shell script "/sbin/ifconfig bridge0 alias " & quoted form of managementAddress & " netmask " & quoted form of managementMask with administrator privileges
            set dnsCommand to "/usr/sbin/networksetup -setdnsservers " & quoted form of serviceName
            if dnsCount is 0 then
                set dnsCommand to dnsCommand & " Empty"
            else
                repeat with indexValue from 1 to dnsCount
                    set dnsCommand to dnsCommand & " " & quoted form of (item (4 + indexValue) of argv)
                end repeat
            end if
            do shell script dnsCommand with administrator privileges
        end run
        """
        let arguments = [serviceName, address, subnetMask, String(dnsServers.count)] + dnsServers
        return run(executable: "/usr/bin/osascript", arguments: ["-e", script] + arguments)
    }

    func runPrivilegedRemoveManagementAlias(address: String) -> NetworkModeCommandResult {
        let script = """
        on run argv
            do shell script "/sbin/ifconfig bridge0 -alias " & quoted form of (item 1 of argv) with administrator privileges
        end run
        """
        return run(executable: "/usr/bin/osascript", arguments: ["-e", script, address])
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

    func readLocalSnapshot() throws -> NetworkModeSnapshot { try collectSnapshot(qualify: false) }
    func qualifySnapshot(_ local: NetworkModeSnapshot) throws -> NetworkModeSnapshot { try readSnapshot() }
    func readSnapshot() throws -> NetworkModeSnapshot { try collectSnapshot(qualify: true) }
    private func collectSnapshot(qualify: Bool) throws -> NetworkModeSnapshot {
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
        var bridgeIPv4: String?

        var gateway: String?
        var bridgeConfigurationUsesDHCP = false
        if let thunderboltService {
            let infoResult = commandRunner.run(
                executable: "/usr/sbin/networksetup",
                arguments: ["-getinfo", thunderboltService.name]
            )
            if infoResult.succeeded {
                gateway = Self.parseNetworkInfoValue("Router", from: infoResult.standardOutput)
                bridgeConfigurationUsesDHCP = infoResult.standardOutput.contains("DHCP Configuration")
                let leasedAddress = Self.parseNetworkInfoValue("IP address", from: infoResult.standardOutput)
                if let leasedAddress,
                   leasedAddress != profile.managementLocalAddress,
                   !MacMiniLinkProfile.isLinkLocalIPv4(leasedAddress),
                   bridgeAddresses.contains(leasedAddress) {
                    bridgeIPv4 = leasedAddress
                }
            }
        }
        if bridgeIPv4 == nil {
            bridgeIPv4 = bridgeAddresses.first {
                $0 != profile.managementLocalAddress && !MacMiniLinkProfile.isLinkLocalIPv4($0)
            }
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
        if qualify, bridgeActive,
           bridgeConfigurationUsesDHCP,
           bridgeAddresses.contains(profile.managementLocalAddress) {
            let pingResult = commandRunner.run(
                executable: "/sbin/ping",
                arguments: [
                    "-b", thunderboltService?.device ?? "bridge0",
                    "-S", profile.managementLocalAddress,
                    "-c", "1", "-W", "500", profile.managementMiniAddress
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
        } else if !bridgeConfigurationUsesDHCP ||
                    !bridgeAddresses.contains(profile.managementLocalAddress) {
            linkState = .addressNotProvisioned
        } else if qualify && !miniReachable {
            linkState = .miniUnreachable
        } else {
            linkState = .connected
        }

        let gatewayState: MacMiniGatewayState
        if !qualify || linkState != .connected {
            gatewayState = .unknown
        } else if bridgeIPv4 == nil || gateway == nil || gateway == "none" || gateway == "0.0.0.0" {
            gatewayState = readMacMiniHelperStatus().flatMap { !$0.sharingIntentEnabled ? .sharingManualPending : nil } ?? .dhcpLeaseRecovering
        } else {
            // Take the cheap, decisive remote evidence first.  A managed upstream can reject
            // every bound-direct probe, and those burn the whole round budget; reading the
            // helper afterwards would then be killed by the parent deadline and report
            // `remoteStatusUnavailable` for a Mini that is provably healthy.
            let remoteStatus = readMacMiniHelperStatus()
            let device = thunderboltService?.device ?? "bridge0"
            let hasBoundEgress = Self.boundDirectEgressReady(
                device: device,
                physicalDefaultInterface: physicalDefaultInterface,
                targets: profile.httpsProbeTargets
            ) { target in
                self.commandRunner.run(
                    executable: "/usr/bin/curl",
                    arguments: [
                        "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                        "--connect-timeout", "2", "--max-time", "4", "--max-redirs", "0",
                        "--interface", device,
                        "--noproxy", "*", target
                    ]
                ).isSuccessfulConnectivityHTTPResponse(for: target)
            }
            if hasBoundEgress {
                gatewayState = .ready
            } else if let remoteStatus {
                let remoteState = remoteStatus.gatewayState
                // A managed upstream may reject direct-bypass HTTPS even though
                // the fixed link, forwarding and native sharing are locally
                // healthy.  Remote `ready` is sufficient to *qualify* a trial
                // switch; the route transaction still has to prove the MacBook
                // system/Clash/TUN data plane before commit.  Unknown remote
                // evidence remains unknown and never qualifies a switch.
                gatewayState = remoteState
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
            miniGateway: gateway,
            physicalDefaultInterface: physicalDefaultInterface,
            linkState: linkState,
            gatewayState: gatewayState,
            physicalLinkActive: bridgeActive,
            observedAt: Date()
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

    /// One bound-direct verdict per round (FR-003: same-generation evidence is reused).
    /// The key carries the physical default interface, so a route write inside the round
    /// asks a different question and re-probes instead of reusing a pre-switch answer.
    static func boundDirectEgressReady(
        device: String,
        physicalDefaultInterface: String?,
        targets: [String],
        probe: (String) -> Bool
    ) -> Bool {
        guard let context = ProbeContext.current?.root else { return targets.contains(where: probe) }
        return context.memoized("bound-direct:\(device)@\(physicalDefaultInterface ?? "-")") {
            targets.contains(where: probe)
        }
    }

    func readMacMiniHelperStatus() -> MacMiniHelperStatus? {
        if let context = ProbeContext.current {
            return context.memoized("mini-helper-status") { fetchMacMiniHelperStatus() }
        }
        return fetchMacMiniHelperStatus()
    }
    private func fetchMacMiniHelperStatus() -> MacMiniHelperStatus? {
        #if APP_STORE
        return nil
        #else
        let result = commandRunner.run(
            executable: "/usr/bin/ssh",
            arguments: NetworkLinkProvisioner.sshArguments(
                profile: profile,
                host: profile.managementMiniAddress,
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
            // Unreadable remote status downgrades the whole snapshot, so say why:
            // a killed command, a refused login and a schema drift need different fixes.
            NetworkEventLogger.shared.record(
                event: "mini_status_read_failed",
                detail: "exit=\(result.exitCode) out=\(result.standardOutput.count)B err=\(result.standardError.prefix(120))",
                candidateSSID: nil
            )
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
                host: profile.managementMiniAddress,
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
    @Published private(set) var miniHelperStatus: MacMiniHelperStatus?
    @Published private(set) var isSwitching = false
    @Published private(set) var isProvisioning = false
    @Published private(set) var isRepairingDNS = false
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
    @Published private(set) var currentUnderlayVerified = false
    @Published private(set) var dnsPathFacts: DNSPathFacts?
    @Published private(set) var applicationPathFacts: ApplicationPathFacts?
    @Published private(set) var connectivityProofLevel: ConnectivityProofLevel = .unavailable

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
    private let policyShadow: NetworkPolicyShadowCoordinator?
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let sleeper: (TimeInterval) -> Void
    private let workQueue = DispatchQueue(label: "com.zjah.NetBar.network-mode", qos: .utility)
    private lazy var policyScheduler = LatestEvaluation(queue: workQueue)
    private lazy var refreshScheduler = LatestEvaluation(queue: workQueue)
    private lazy var wifiRefreshScheduler = LatestEvaluation(queue: DispatchQueue(label: "com.zjah.NetBar.wifi-refresh", qos: .utility))
    private var retryStep = 0
    private var lastMiniQualificationAt: Date?
    private var miniQualifyingSamples = 0
    /// A gap this large means sampling actually stopped (sleep, pause, a stuck round),
    /// not that one qualification round was slow.  Sized to the stability window itself;
    /// `minimumMiniQualifyingSamples` is what stops two far-apart samples from passing.
    private static let miniQualificationGapTolerance: TimeInterval = 30
    private static let minimumMiniQualifyingSamples = 3
    private let onNetworkChanged: () -> Void
    private var policyTimer: Timer?
    private var policyEventWorkItem: DispatchWorkItem?
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
        policyShadow: NetworkPolicyShadowCoordinator? = nil,
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
        self.policyShadow = policyShadow
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
        workQueue.async { [weak self] in
            guard let self else { return }
            let available = self.routeSafetyController.status() != nil
            _ = self.routeSafetyController.ensureManagementAlias()
            DispatchQueue.main.async { self.automationHelperAvailable = available }
        }
        reconcilePendingRouteTransaction()
        refresh()
        refreshWiFiCandidates()
        wifiCandidateController.startMonitoring { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshWiFiCandidates()
                self.schedulePolicyCheckAfterNetworkChange(.other)
            }
        }
        networkChangeObserver.start { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if event == .physicalLink {
                    Log.network.info("收到物理链路变化事件，立即重新评估出口")
                    // Management maintenance is coalesced with the next policy evaluation.
                }
                let reaction = event.reaction(
                    preference: self.routePreference,
                    activeMode: self.snapshot?.effectiveMode
                )
                if let message = reaction.message {
                    self.policyMessage = message
                }
                self.schedulePolicyCheckAfterNetworkChange(event, fallbackDelay: reaction.delay)
            }
        }
        guard policyTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.performPolicyCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        policyTimer = timer
        performPolicyCheck(force: true)
    }

    func stopPolicyMonitoring() {
        policyScheduler.cancel()
        refreshScheduler.cancel()
        wifiRefreshScheduler.cancel()
        policyTimer?.invalidate()
        policyTimer = nil
        policyEventWorkItem?.cancel()
        policyEventWorkItem = nil
        wifiCandidateController.stopMonitoring()
        networkChangeObserver.stop()
        if let policyShadow { Task { await policyShadow.stop() } }
    }

    func runPolicyCheckNow() {
        performPolicyCheck(force: true)
    }

    func requestWiFiLocationAccess() {
        wifiCandidateController.requestLocationAccess()
    }

    func refreshWiFiCandidates() {
        wifiRefreshScheduler.submit(timeout: 5) { [weak self] context in
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
                guard !context.isCancelled else { return }
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
        refreshScheduler.submit(timeout: 8) { [weak self] context in
            guard let self else { return }
            let result = Result {
                (try self.provider.readLocalSnapshot(), self.provider.readMacMiniHelperStatus())
            }
            DispatchQueue.main.async {
                guard !context.isStopped else { return }
                switch result {
                case .success(let (snapshot, helperStatus)):
                    // `readLocalSnapshot` deliberately skips qualification, so its
                    // `gatewayState` is always `.unknown` — publishing that verbatim erases
                    // the policy round's verdict and makes the card flash
                    // "共享状态未知 / 受限在线" every time the popover opens.  Carry the last
                    // qualified verdict forward while the link facts still match it.
                    var merged = snapshot
                    if merged.gatewayState == .unknown,
                       let previous = self.snapshot,
                       previous.gatewayState != .unknown,
                       previous.linkState == merged.linkState,
                       previous.effectiveMode == merged.effectiveMode {
                        merged.gatewayState = previous.gatewayState
                    }
                    self.snapshot = merged
                    self.miniHelperStatus = helperStatus
                    if !self.requiresManualRecovery {
                        self.errorMessage = nil
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func repairWiFiDNS() {
        guard !isSwitching, !isProvisioning, !isRepairingDNS else { return }
        guard DistributionFlavor.current.supportsNetworkModeSwitch else {
            errorMessage = "App Store Lite 不支持 DNS 修复"
            return
        }
        guard dnsPathFacts?.dependency == .miniDependent else {
            errorMessage = "当前 Wi-Fi DNS 不依赖 Mac mini，无需自动修复"
            return
        }
        isRepairingDNS = true
        errorMessage = nil

        workQueue.async { [weak self] in
            guard let self else { return }
            let status = self.routeSafetyController.status()
            guard status?.protocolVersion == 5 else {
                DispatchQueue.main.async {
                    self.isRepairingDNS = false
                    self.errorMessage = "请先安装或更新自动切换组件"
                }
                return
            }
            let start = self.routeSafetyController.repairWiFiDNS()
            guard start.succeeded else {
                DispatchQueue.main.async {
                    self.isRepairingDNS = false
                    self.errorMessage = start.combinedMessage.isEmpty ? "Wi-Fi DNS 修复未开始" : start.combinedMessage
                }
                return
            }

            let interface = status?.wifiDevice.isEmpty == false ? (status?.wifiDevice ?? "en0") : "en0"
            var verified: ConnectivityProbeResult?
            for attempt in 0..<6 {
                let probe = self.connectivityProber.probe(interfaceName: interface)
                self.publishConnectivityFacts(probe)
                if probe.dnsPath.configurationSource == .automatic,
                   probe.dnsPath.systemResolutionReady,
                   probe.dnsPath.dependency != .miniDependent,
                   probe.dnsPath.dependency != .unreachable,
                   probe.routedInternetReady {
                    verified = probe
                    break
                }
                if attempt < 5 { self.sleeper(2) }
            }
            let transactionResult = verified == nil
                ? self.routeSafetyController.rollback()
                : self.routeSafetyController.commit()
            let succeeded = verified != nil && transactionResult.succeeded
            self.eventLogger.record(
                event: "wifi_dns_repair",
                detail: "\(verified == nil ? "rollback" : "commit"): \(transactionResult.succeeded ? "success" : "failed")",
                candidateSSID: nil
            )
            DispatchQueue.main.async {
                self.isRepairingDNS = false
                if succeeded {
                    self.policyMessage = "Wi-Fi 已恢复自动 DNS，端到端数据面验证通过"
                    self.errorMessage = nil
                    self.onNetworkChanged()
                } else {
                    self.errorMessage = transactionResult.succeeded
                        ? "自动 DNS 未在时限内恢复网络，已还原原配置"
                        : "DNS 事务无法完整恢复，需要手动检查网络设置"
                    self.requiresManualRecovery = !transactionResult.succeeded
                }
            }
        }
    }

    func removeLegacyMiniDNS() {
        guard !isSwitching, !isProvisioning, !isRepairingDNS else { return }
        guard DistributionFlavor.current.supportsNetworkModeSwitch else {
            errorMessage = "App Store Lite 不支持 DNS 清理"
            return
        }
        guard dnsPathFacts?.hasLegacyMiniResolver == true else {
            errorMessage = "当前 Wi-Fi DNS 不包含旧 Mac mini 地址"
            return
        }
        isRepairingDNS = true
        errorMessage = nil

        workQueue.async { [weak self] in
            guard let self else { return }
            let status = self.routeSafetyController.status()
            guard status?.protocolVersion == 5,
                  status?.wifiDNSLegacyMiniResolverPresent == true else {
                DispatchQueue.main.async {
                    self.isRepairingDNS = false
                    self.errorMessage = "请先安装或更新自动切换组件"
                }
                return
            }
            let start = self.routeSafetyController.removeLegacyMiniDNS()
            guard start.succeeded else {
                DispatchQueue.main.async {
                    self.isRepairingDNS = false
                    self.errorMessage = start.combinedMessage.isEmpty ? "旧 Mini DNS 清理未开始" : start.combinedMessage
                }
                return
            }

            let interface = status?.wifiDevice.isEmpty == false ? (status?.wifiDevice ?? "en0") : "en0"
            var verified: ConnectivityProbeResult?
            for attempt in 0..<6 {
                let probe = self.connectivityProber.probe(interfaceName: interface)
                self.publishConnectivityFacts(probe)
                if !probe.dnsPath.hasLegacyMiniResolver,
                   probe.dnsPath.effectiveDNSReady,
                   probe.routedInternetReady {
                    verified = probe
                    break
                }
                if attempt < 5 { self.sleeper(2) }
            }
            let transactionResult = verified == nil
                ? self.routeSafetyController.rollback()
                : self.routeSafetyController.commit()
            let succeeded = verified != nil && transactionResult.succeeded
            self.eventLogger.record(
                event: "wifi_legacy_mini_dns_cleanup",
                detail: "\(verified == nil ? "rollback" : "commit"): \(transactionResult.succeeded ? "success" : "failed")",
                candidateSSID: nil
            )
            DispatchQueue.main.async {
                self.isRepairingDNS = false
                if succeeded {
                    self.policyMessage = "已清理旧 Mini DNS，保留其余手动 DNS"
                    self.errorMessage = nil
                    self.onNetworkChanged()
                } else {
                    self.errorMessage = transactionResult.succeeded
                        ? "清理后网络未通过验证，已还原原 DNS"
                        : "DNS 事务无法完整恢复，需要手动检查网络设置"
                    self.requiresManualRecovery = !transactionResult.succeeded
                }
            }
        }
    }

    func switchMode(to target: NetworkRouteMode) {
        guard !isSwitching, !isProvisioning else { return }
        policyScheduler.cancel()
        refreshScheduler.cancel()
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
            let helperAvailable = self.routeSafetyController.status() != nil
            let helperResult = helperAvailable
                ? self.routeSafetyController.apply(.macMiniGateway)
                : NetworkModeCommandResult(
                    exitCode: 1,
                    standardOutput: "",
                    standardError: "请先安装或更新自动切换组件；完成一次管理员授权后，普通切换不再请求密码"
                )
            var outcome: NetworkModeSwitchOutcome
            if helperAvailable {
                let refreshed = try? self.provider.readSnapshot()
                let rebindResult = refreshed.map {
                    self.rebindMihomoUnderlayIfNeeded(
                        snapshot: $0,
                        previousHint: previousMode,
                        at: self.now()
                    )
                }
                let dataPlaneVerified = helperResult.succeeded && refreshed?.verifies(.macMiniGateway) == true &&
                    self.verifyDataPlane(
                        interfaceName: refreshed?.thunderboltDevice ?? "bridge0",
                        afterRebind: rebindResult == .succeeded
                    ).routedInternetReady
                let verified = dataPlaneVerified && self.routeSafetyController.commit().succeeded
                if helperResult.succeeded && !verified {
                    _ = self.routeSafetyController.rollback()
                }
                outcome = NetworkModeSwitchOutcome(
                    kind: verified ? .success : .failed,
                    snapshot: refreshed,
                    message: verified ? nil : (helperResult.combinedMessage.isEmpty ? "Mac mini 数据面验证失败" : helperResult.combinedMessage)
                )
            } else {
                outcome = NetworkModeSwitchOutcome(
                    kind: .failed,
                    snapshot: try? self.provider.readSnapshot(),
                    message: helperResult.combinedMessage
                )
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
                self.currentUnderlayVerified = outcome.succeeded
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
        let shadowCandidates = wifiCandidates
        let shadowUnderlayVerified = currentUnderlayVerified
        let shadowConnectivityProof = connectivityProofLevel
        let shadowDNSPath = dnsPathFacts
        let shadowApplicationPath = applicationPathFacts
        let queuedAt = ProbeContext.monotonicNow
        policyScheduler.submit(timeout: 25, superseding: force) { [weak self] context in
            guard let self else { return }
            if force { self.nextWiFiFallbackAttemptAt = nil }

            self.reconcilePendingRouteTransactionNow()
            guard !context.isStopped else { return }
            let preference = self.currentPreference()

            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + context.remaining) { [weak self] in
                guard finished.wait(timeout: .now()) == .timedOut, !context.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.policyMessage = "恢复检查已超时，正在核对当前出口"
                }
            }
            defer { finished.signal() }
            let started = ProbeContext.monotonicNow
            self.eventLogger.record(event: "recovery_stage", detail: "id=\(context.recoveryID) generation=\(context.generation) phase=begin queued_ms=\(Int((started - queuedAt) * 1000))", candidateSSID: nil)
            defer {
                let outcome = context.isCancelled ? "cancelled" : context.remaining == 0 ? "timedOut" : "finished"
                self.eventLogger.record(event: "recovery_stage", detail: "id=\(context.recoveryID) phase=end result=\(outcome) elapsed_ms=\(Int((ProbeContext.monotonicNow - started) * 1000))", candidateSSID: nil)
                if context.remaining == 0 && !context.isCancelled {
                    self.policyState.readySince = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.policyMessage = "本轮验证超时，保持当前出口并等待重新检测"
                        self?.isSwitching = false
                    }
                }
            }
            guard let local = try? self.provider.readLocalSnapshot(), !context.isStopped else { return }
            let current: NetworkModeSnapshot
            if local.linkState == .disconnected || local.linkState == .unavailable || local.linkState == .addressNotProvisioned {
                current = local
            } else {
                current = (try? self.provider.qualifySnapshot(local)) ?? local
            }
            guard !context.isStopped else { return }
            let checkDate = self.now()
            if let policyShadow = self.policyShadow {
                let observation = NetworkPolicyShadowObservation.make(
                    snapshot: current,
                    preference: preference,
                    currentUnderlayVerified: shadowUnderlayVerified,
                    wifiCandidates: shadowCandidates,
                    connectivityProofLevel: shadowConnectivityProof,
                    dnsPath: shadowDNSPath,
                    applicationPath: shadowApplicationPath,
                    observedAt: checkDate
                )
                Task { await policyShadow.observe(observation) }
            }
            _ = self.rebindMihomoUnderlayIfNeeded(snapshot: current, previousHint: nil, at: checkDate)
            guard preference == .miniPreferred else { return }
            self.policyState.clearExpiredCircuitBreaker(at: checkDate)
            self.persistPolicyState()
            let helperAvailable = self.routeSafetyController.status() != nil
            if current.linkState == .addressNotProvisioned { _ = self.routeSafetyController.ensureManagementAlias() }
            let guardianAvailable = self.knownMiniGuardianAvailable
            DispatchQueue.main.async { [weak self] in
                self?.miniGuardianAvailable = guardianAvailable
            }

            // A managed network can reject interface-bound direct HTTPS while the
            // selected TUN/proxy data plane remains healthy.  When Mini is already
            // the real physical underlay, prefer the fresh end-to-end proof over
            // the legacy bound-direct gateway classification.  This path never
            // qualifies an inactive Mini candidate and therefore cannot trigger a
            // speculative switch.
            if current.effectiveMode == .macMiniGateway,
               current.gatewayState != .ready {
                let activeProbe = self.connectivityProber.probe(
                    interfaceName: current.thunderboltDevice ?? "bridge0"
                )
                self.publishConnectivityFacts(activeProbe)
                if activeProbe.physicalDefaultInterface == (current.thunderboltDevice ?? "bridge0"),
                   activeProbe.proofLevel == .activeVerified {
                    self.handleHealthySnapshot(
                        current,
                        at: checkDate,
                        helperAvailable: helperAvailable,
                        initialProbe: activeProbe
                    )
                    return
                }
            }

            // The facts the decision was made on.  Deduplication keeps this to one record
            // per distinct state, so a stuck policy says what it is looking at.
            self.eventLogger.record(
                event: "policy_snapshot",
                detail: "link=\(current.linkState) gateway=\(current.gatewayState) effective=\(current.effectiveMode.map(String.init(describing:)) ?? "-") helper=\(helperAvailable)",
                candidateSSID: nil
            )
            if current.linkState == .connected, current.gatewayState == .ready {
                self.handleHealthySnapshot(current, at: checkDate, helperAvailable: helperAvailable)
            } else {
                self.handleUnhealthySnapshot(current, at: checkDate, helperAvailable: helperAvailable)
            }
        }
    }

    private func schedulePolicyCheckAfterNetworkChange(
        _ event: NetworkChangeEvent,
        fallbackDelay: TimeInterval = 0.25
    ) {
        if let policyShadow { Task { await policyShadow.networkDidChange(event) } }
        guard policyEventWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.policyEventWorkItem = nil
            self.performPolicyCheck(force: true)
        }
        policyEventWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + min(0.25, fallbackDelay), execute: workItem)
    }

    private func handleHealthySnapshot(
        _ current: NetworkModeSnapshot,
        at checkDate: Date,
        helperAvailable: Bool,
        initialProbe: ConnectivityProbeResult? = nil
    ) {
        let miniProbe = initialProbe ?? connectivityProber.probe(
            interfaceName: current.thunderboltDevice ?? "bridge0"
        )
        publishConnectivityFacts(miniProbe)
        let boundMiniReachable = current.linkState == .connected && current.gatewayState == .ready
        let activeEndToEndVerified = current.effectiveMode == .macMiniGateway &&
            miniProbe.physicalDefaultInterface == (current.thunderboltDevice ?? "bridge0") &&
            miniProbe.proofLevel == .activeVerified
        guard miniProbe.directInternetReady || boundMiniReachable || activeEndToEndVerified else {
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
                      reconciled.verifies(.macMiniGateway),
                      routeSafetyController.commit().succeeded else {
                    if orderResult.succeeded { _ = routeSafetyController.rollback() }
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
        if let last = lastMiniQualificationAt,
           checkDate.timeIntervalSince(last) > Self.miniQualificationGapTolerance {
            policyState.readySince = nil
            miniQualifyingSamples = 0
        }
        lastMiniQualificationAt = checkDate
        miniQualifyingSamples += 1
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
        // Stability needs both duration and repeated evidence: a slow qualification round
        // must still count, while two samples far apart must not add up to 30 seconds.
        let elapsed = policyState.stableDuration(at: checkDate)
        guard elapsed >= 30, miniQualifyingSamples >= Self.minimumMiniQualifyingSamples else {
            let remaining = max(0, Int(ceil(30 - elapsed)))
            eventLogger.record(
                event: "mini_stabilizing",
                detail: "elapsed=\(Int(elapsed))s samples=\(miniQualifyingSamples)",
                candidateSSID: nil
            )
            publishPolicy(snapshot: current, message: "Mac mini 已恢复，稳定 \(remaining) 秒后自动切回", remaining: remaining)
            return
        }
        let remoteStatus = provider.readMacMiniHelperStatus()
        guard let remote = remoteStatus,
              remote.gatewayState == .ready,
              remote.guardianIsFresh(at: checkDate) else {
            let reason: String
            if let remote = remoteStatus {
                reason = remote.gatewayState != .ready
                    ? "remote=\(remote.gatewayState)"
                    : "guardian stale at \(remote.guardianObservedAt ?? "-")"
            } else {
                reason = "remote status unreadable"
            }
            eventLogger.record(event: "mini_qualification_blocked", detail: reason, candidateSSID: nil)
            publishPolicy(snapshot: current, message: "等待 Mac mini Guardian 确认共享稳定", remaining: nil)
            return
        }
        recordMiniGuardianAvailability(true)
        DispatchQueue.main.async { [weak self] in
            self?.miniGuardianAvailable = true
        }
        guard helperAvailable else {
            eventLogger.record(event: "mini_qualification_blocked", detail: "route safety helper unavailable", candidateSSID: nil)
            publishPolicy(snapshot: current, message: "Mac mini 已恢复；需安装自动切换组件", remaining: nil, helperAvailable: false)
            return
        }
        guard currentPreference() == .miniPreferred else {
            eventLogger.record(event: "mini_qualification_blocked", detail: "preference is not miniPreferred", candidateSSID: nil)
            return
        }
        eventLogger.record(event: "mini_trial_switch", detail: "stable \(Int(elapsed))s over \(miniQualifyingSamples) samples", candidateSSID: nil)

        // The route write itself makes macOS post a network change, which re-enters
        // performPolicyCheck(force:) and supersedes — i.e. cancels — the very round doing
        // the write.  Everything after apply() then aborts: convergence returns at once,
        // the Clash controller read reports "unavailable", the data-plane probe never runs,
        // and a switch that was working gets rolled back.  Run the transaction on its own
        // uncancellable budget so it always reaches commit or rollback.
        // The transaction must survive being superseded, but that is cancellation immunity,
        // not a fresh 25-second budget: only start when the round still has room for it.
        let roundRemaining = ProbeContext.current?.remaining ?? 20
        guard roundRemaining >= 12 else {
            eventLogger.record(
                event: "mini_qualification_blocked",
                detail: "insufficient round budget: \(Int(roundRemaining))s",
                candidateSSID: nil
            )
            return
        }
        ProbeContext.withValue(ProbeContext(timeout: min(20, roundRemaining))) {
            let result = routeSafetyController.apply(.macMiniGateway)
            // The service order is written synchronously, the physical default interface is not.
            // Judging `verifies` at t+0 records a spurious failure (and two of those trip the
            // 600s flap breaker) for a switch that converges a second later.
            let verified = result.succeeded ? awaitRouteConvergence(to: .macMiniGateway, budget: 8) : nil
            let rebindResult = verified.map {
                rebindMihomoUnderlayIfNeeded(snapshot: $0, previousHint: current.effectiveMode, at: checkDate)
            }
            let finalMiniProbe = verified.map {
                verifyDataPlane(
                    interfaceName: $0.thunderboltDevice ?? "bridge0",
                    afterRebind: rebindResult == .succeeded,
                    convergenceBudget: 8
                )
            }
            // Each of these can veto the switch, and the popover only ever shows the outcome.
            // Record which one did, or the next failure costs another live bisect.
            let verifiesTarget = verified?.verifies(.macMiniGateway) == true
            let dataPlaneReady = finalMiniProbe?.routedInternetReady == true
            let committed = verifiesTarget && dataPlaneReady
                ? routeSafetyController.commit().succeeded
                : false
            if !committed {
                eventLogger.record(
                    event: "mini_trial_switch_failed",
                    detail: "applied=\(result.succeeded) verifies=\(verifiesTarget) dataPlane=\(dataPlaneReady) committed=\(committed) effective=\(verified?.effectiveMode.map(String.init(describing:)) ?? "-") intended=\(verified?.intendedMode.map(String.init(describing:)) ?? "-") rebind=\(rebindResult.map(String.init(describing:)) ?? "-")",
                    candidateSSID: nil
                )
            }
            if let verified, committed {
                policyState.markMiniActive()
                policyState.recordAutomaticReturn(at: checkDate)
                persistPolicyState()
                publishPolicy(snapshot: verified, message: "已自动切回 Mac mini", remaining: nil, helperAvailable: true, activeCandidate: "Mac mini")
                Log.network.info("Mac mini 上游稳定 30 秒，已自动切回雷雳出口")
                eventLogger.record(event: "automatic_return_to_mini", detail: "30-second stability and full data plane verified", candidateSSID: nil)
                DispatchQueue.main.async { [weak self] in self?.onNetworkChanged() }
            } else {
                if result.succeeded { _ = routeSafetyController.rollback() }
                policyState.recordFailedAutomaticReturn(at: checkDate)
                persistPolicyState()
                let restored = fallbackToVerifiedWiFi(at: checkDate, reason: "自动切回验证失败", automatic: true)
                if !restored {
                    let refreshed = (try? provider.readSnapshot()) ?? current
                    publishPolicy(snapshot: refreshed, message: "自动切回失败，且没有可验证的 Wi-Fi 候选", remaining: nil, helperAvailable: true, isError: true)
                }
                Log.network.error("自动切回 Mac mini 失败，Wi-Fi 恢复=\(restored)")
            }
        }
    }

    private func handleUnhealthySnapshot(
        _ current: NetworkModeSnapshot,
        at checkDate: Date,
        helperAvailable: Bool
    ) {
        guard ProbeContext.current?.isStopped != true else { return }
        miniQualifyingSamples = 0
        policyState.recordFailure()
        var definitiveFailure: Bool
        switch current.linkState {
        case .disconnected, .unavailable, .addressNotProvisioned:
            definitiveFailure = true
        case .connected, .miniUnreachable:
            definitiveFailure = false
        }
        switch current.gatewayState {
        case .carrierDown, .addressRecovering, .sharingRecovering, .sharingForwardingUnavailable,
             .configurationDrift, .recoveryBackoff, .sharingManualPending,
             .managementLinkRecovering, .dhcpLeaseRecovering, .hotspotClientUnverified:
            definitiveFailure = true
        default:
            break
        }

        if !definitiveFailure {
            let parent = ProbeContext.current
            let confirmationDeadline = ProbeContext.monotonicNow + min(8, parent?.remaining ?? 8)
            var consecutiveHTTPSFailures = 0
            var attempted = 0
            var ranOutOfBudget = false
            for _ in 0..<2 {
                let remaining = confirmationDeadline - ProbeContext.monotonicNow
                guard remaining > 0, parent?.isStopped != true else { ranOutOfBudget = true; break }
                // Each round must gather its own evidence: a shared scope would memoize the
                // first round's bound-direct result and make "two rounds" a single sample.
                let round = ProbeContext(generation: parent?.generation ?? 0, timeout: remaining)
                attempted += 1
                let probe = ProbeContext.withValue(round) { connectivityProber.probe(interfaceName: current.thunderboltDevice ?? "bridge0") }
                publishConnectivityFacts(probe)
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
                if round.remaining <= 0 { ranOutOfBudget = true; break }
            }
            // A soft failure is only confirmed when every round it managed to run said so.
            // Running out of budget, or being cancelled, is unknown — not evidence of failure.
            definitiveFailure = !ranOutOfBudget
                && attempted == 2
                && consecutiveHTTPSFailures == attempted
                && parent?.isCancelled != true
        }

        guard definitiveFailure else {
            publishPolicy(snapshot: current, message: current.gatewayState.displayName, remaining: nil)
            return
        }

        policyState.beginWiFiFallback(at: checkDate)
        persistPolicyState()

        if current.effectiveMode == .macMiniGateway,
           current.linkState == .connected,
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
            publishConnectivityFacts(wifiProbe)
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
        let restored = fallbackToVerifiedWiFi(
            at: checkDate,
            reason: reason,
            automatic: true,
            keepRouteWhenSourceUnavailable: true
        )
        if !restored {
            nextWiFiFallbackAttemptAt = now().addingTimeInterval([5.0, 15.0, 30.0][min(retryStep, 2)])
            retryStep += 1
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
    private func fallbackToVerifiedWiFi(
        at checkDate: Date,
        reason: String,
        automatic: Bool,
        keepRouteWhenSourceUnavailable: Bool = false
    ) -> Bool {
        fallbackFailureMessage = nil
        let pinned = candidateStore.load()
        let wifi = wifiCandidateController.snapshot(pinnedSSIDs: pinned)
        var candidates = wifi.candidates.filter { $0.isPinned && $0.state != .unavailable }
        if candidates.isEmpty,
           wifi.currentSSID == nil,
           connectivityProber.probeLocal(interfaceName: wifi.interfaceName).hasLocalNetwork {
            // Location access can redact the current SSID. Reusing the already-associated
            // interface does not expand the whitelist or attempt any unknown network.
            candidates = [WiFiCandidateSelector.anonymousCurrentCandidate(interfaceName: wifi.interfaceName)]
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
            let parent = ProbeContext.current
            guard parent?.isStopped != true else { return false }
            // Detached on purpose: the rescue writes the route, macOS posts a change, and the
            // parent round is superseded — abandoning a half-written rescue is worse than
            // finishing it.  15 seconds is the candidate budget from FR-005, now real.
            let candidateContext = ProbeContext(generation: parent?.generation ?? 0, timeout: 15)
            ProbeContext.install(candidateContext)
            defer { ProbeContext.install(parent) }
            let wifiInterface = candidate.interfaceName.isEmpty ? "en0" : candidate.interfaceName
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

            let directProbe = connectivityProber.probeLocal(interfaceName: wifiInterface)
            publishConnectivityFacts(directProbe)
            guard directProbe.hasLocalNetwork else {
                let state: NetworkCandidateState = .localOnly
                fallbackFailureMessage = state.displayName
                updateCandidateState(ssid: candidate.displayName, state: state, current: true)
                eventLogger.record(event: "wifi_candidate_rejected", detail: state.displayName, candidateSSID: candidate.displayName)
                continue
            }

            let current = try? provider.readLocalSnapshot()
            var routeTransactionStarted = false
            if current?.effectiveMode != .localWiFi || current?.intendedMode != .localWiFi {
                let helperAvailable = routeSafetyController.status() != nil
                let routeResult: NetworkModeCommandResult
                if helperAvailable {
                    routeResult = routeSafetyController.apply(.localWiFi)
                    routeTransactionStarted = routeResult.succeeded
                } else {
                    routeResult = .init(exitCode: 1, standardOutput: "", standardError: "自动切换组件未安装")
                }
                guard routeResult.succeeded else {
                    fallbackFailureMessage = routeResult.combinedMessage.isEmpty ? "Wi-Fi 路由切换失败" : routeResult.combinedMessage
                    eventLogger.record(event: "wifi_route_switch_failed", detail: routeResult.combinedMessage, candidateSSID: candidate.displayName)
                    continue
                }
            }

            // Same asymmetry the Mini trial switch already fixed: the service order is written
            // synchronously, the physical default interface is not.  Judging at t+0 rolled the
            // rescue back — and when the source is already known dead, rolling back restores a
            // route that provably does not work.
            let converged = routeTransactionStarted
                ? awaitRouteConvergence(to: .localWiFi, budget: 8, qualify: false)
                : ((try? provider.readLocalSnapshot()) ?? current)
            guard let refreshed = converged ?? current,
                  refreshed.effectiveMode == .localWiFi,
                  refreshed.intendedMode == .localWiFi else {
                if routeTransactionStarted, !keepRouteWhenSourceUnavailable {
                    _ = routeSafetyController.rollback()
                }
                fallbackFailureMessage = "Wi-Fi 服务顺序已修改，但默认物理出口验证失败"
                eventLogger.record(
                    event: "wifi_route_verification_failed",
                    detail: "\(reason) rolledBack=\(routeTransactionStarted && !keepRouteWhenSourceUnavailable)",
                    candidateSSID: candidate.displayName
                )
                continue
            }

            publishPolicy(snapshot: refreshed, message: "Wi-Fi 已接管，正在验证", remaining: nil, activeCandidate: candidate.displayName)
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
                interfaceName: wifiInterface,
                initialProbe: directProbe,
                underlayRebound: rebindResult == .succeeded,
                at: checkDate
            )
            if routeTransactionStarted {
                let physicalPathVerified = directProbe.directInternetReady || convergence ||
                    (keepRouteWhenSourceUnavailable && directProbe.hasLocalNetwork)
                if physicalPathVerified {
                    guard routeSafetyController.commit().succeeded else {
                        _ = routeSafetyController.rollback()
                        fallbackFailureMessage = "Wi-Fi 路由事务提交失败"
                        continue
                    }
                } else {
                    _ = routeSafetyController.rollback()
                    fallbackFailureMessage = "Wi-Fi 数据面验证失败，已恢复原服务顺序"
                    continue
                }
            }
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
            retryStep = 0
            lastLoggedFallbackFailureReason = nil
            DispatchQueue.main.async { [weak self] in self?.onNetworkChanged() }
            return true
        }
        return false
    }

    private func convergeClashAfterWiFiSwitch(
        ssid: String,
        interfaceName: String,
        initialProbe: ConnectivityProbeResult,
        underlayRebound: Bool,
        at checkDate: Date
    ) -> Bool {
        let probe = connectivityProber.probe(interfaceName: interfaceName)
        if probe.completeInternetReady || probe.routedInternetReady {
            updateCandidateState(ssid: ssid, state: .internetReady, current: true)
            return true
        }
        if underlayRebound {
            updateCandidateState(ssid: ssid, state: .proxyDegraded, current: true)
            return false // next timer/event verifies; never hold the write queue for retries
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
        return .succeeded
    }

    /// Waits, within a bounded and cancellable window, for the written route to become the
    /// effective one.  Polls the cheap local snapshot and only qualifies once it matches.
    private func awaitRouteConvergence(
        to target: NetworkRouteMode,
        budget: TimeInterval,
        qualify: Bool = true
    ) -> NetworkModeSnapshot? {
        let context = ProbeContext.current
        let deadline = ProbeContext.monotonicNow + min(budget, context?.remaining ?? budget)
        // Only the local facts settle here; `gatewayState` needs qualification, and
        // `readLocalSnapshot` always reports it as unknown — so convergence is judged on
        // intended == effective alone.  The attempt cap keeps this bounded even when the
        // injected sleeper does not actually wait.
        let maximumAttempts = max(1, Int(budget.rounded()))
        var attempts = 0
        while true {
            if let local = try? provider.readLocalSnapshot(),
               local.intendedMode == target,
               local.effectiveMode == target {
                if attempts > 0 {
                    eventLogger.record(
                        event: "route_convergence",
                        detail: "target=\(target) attempts=\(attempts)",
                        candidateSSID: nil
                    )
                }
                return qualify ? ((try? provider.qualifySnapshot(local)) ?? local) : local
            }
            guard attempts < maximumAttempts,
                  ProbeContext.monotonicNow < deadline,
                  context?.isStopped != true else { break }
            sleeper(1)
            attempts += 1
        }
        eventLogger.record(
            event: "route_convergence",
            detail: "target=\(target) attempts=\(attempts) result=timedOut",
            candidateSSID: nil
        )
        return qualify ? (try? provider.readSnapshot()) : (try? provider.readLocalSnapshot())
    }

    /// A route write makes the overlay reconfigure: for about a second afterwards the Clash
    /// controller stops answering, and `routedInternetReady` then falls back to bound-direct
    /// HTTPS, which a managed upstream refuses outright.  Probing once at that instant judges
    /// every trial switch a failure, so allow a bounded, cancellable convergence window —
    /// still inside the round budget, and it returns the moment the data plane is proven.
    private func verifyDataPlane(
        interfaceName: String,
        afterRebind: Bool,
        convergenceBudget: TimeInterval = 0
    ) -> ConnectivityProbeResult {
        var probe = connectivityProber.probe(interfaceName: interfaceName)
        publishConnectivityFacts(probe)
        guard convergenceBudget > 0 else { return probe }
        let context = ProbeContext.current
        let deadline = ProbeContext.monotonicNow + min(convergenceBudget, context?.remaining ?? convergenceBudget)
        var attempts = 0
        while !probe.routedInternetReady,
              ProbeContext.monotonicNow < deadline,
              context?.isStopped != true {
            sleeper(1)
            guard context?.isStopped != true else { break }
            attempts += 1
            probe = connectivityProber.probe(interfaceName: interfaceName)
            publishConnectivityFacts(probe)
        }
        if attempts > 0 {
            eventLogger.record(
                event: "data_plane_convergence",
                detail: "iface=\(interfaceName) attempts=\(attempts) ready=\(probe.routedInternetReady)",
                candidateSSID: nil
            )
        }
        return probe
    }

    private func publishConnectivityFacts(_ probe: ConnectivityProbeResult) {
        let context = ProbeContext.current
        DispatchQueue.main.async { [weak self] in
            guard context?.isCancelled != true else { return }
            self?.dnsPathFacts = probe.dnsPath
            self?.applicationPathFacts = probe.applicationPath
            self?.connectivityProofLevel = probe.proofLevel
            self?.currentUnderlayVerified = probe.proofLevel == .activeVerified
        }
    }

    private func publishPolicy(
        snapshot: NetworkModeSnapshot,
        message: String,
        remaining: Int?,
        helperAvailable: Bool? = nil,
        isError: Bool = false,
        activeCandidate: String? = nil
    ) {
        let context = ProbeContext.current
        DispatchQueue.main.async { [weak self] in
            guard context?.isCancelled != true else { return }
            guard let self else { return }
            self.snapshot = snapshot
            self.policyMessage = message
            self.stabilizationRemaining = remaining
            self.failoverPhase = self.policyState.phase
            if let activeCandidate { self.activeCandidateName = activeCandidate }
            if let helperAvailable { self.automationHelperAvailable = helperAvailable }
            if isError {
                self.currentUnderlayVerified = false
                self.errorMessage = message
            } else if !self.requiresManualRecovery {
                self.currentUnderlayVerified = self.connectivityProofLevel == .activeVerified
                self.errorMessage = nil
            }
        }
    }

    private func reconcilePendingRouteTransaction() {
        workQueue.async { [weak self] in self?.reconcilePendingRouteTransactionNow() }
    }

    private func reconcilePendingRouteTransactionNow() {
            guard let status = self.routeSafetyController.status(), status.pendingTransaction else { return }
            if status.pendingKind == "dns" {
                let probe = self.connectivityProber.probe(interfaceName: status.wifiDevice)
                self.publishConnectivityFacts(probe)
                let verified = status.wifiDNSMode == "automatic" &&
                    status.wifiDNSMiniDependent != true &&
                    probe.dnsPath.systemResolutionReady &&
                    probe.dnsPath.dependency != .miniDependent &&
                    probe.routedInternetReady
                let result = verified
                    ? self.routeSafetyController.commit()
                    : self.routeSafetyController.rollback()
                self.eventLogger.record(
                    event: "dns_transaction_recovered",
                    detail: "\(verified ? "commit" : "rollback"): \(result.succeeded ? "success" : "failed")",
                    candidateSSID: nil
                )
                if !result.succeeded {
                    DispatchQueue.main.async {
                        self.requiresManualRecovery = true
                        self.errorMessage = "未完成的 DNS 事务无法自动恢复"
                    }
                }
                return
            }
            let target: NetworkRouteMode
            switch status.pendingTarget {
            case "mini": target = .macMiniGateway
            case "wifi": target = .localWiFi
            default:
                let rollback = self.routeSafetyController.rollback()
                self.eventLogger.record(
                    event: "route_transaction_recovered",
                    detail: "invalid target rollback: \(rollback.succeeded ? "success" : "failed")",
                    candidateSSID: nil
                )
                if !rollback.succeeded {
                    DispatchQueue.main.async {
                        self.requiresManualRecovery = true
                        self.errorMessage = "路由事务目标损坏，且无法自动恢复"
                    }
                }
                return
            }
            let snapshot = try? self.provider.readSnapshot()
            let interface = target == .macMiniGateway
                ? (snapshot?.thunderboltDevice ?? "bridge0")
                : (snapshot?.wifiDevice ?? "en0")
            let local = self.connectivityProber.probeLocal(interfaceName: interface)
            // A pending Wi-Fi rescue must not restore a dead Mini just because overlay is still converging.
            let verified = snapshot?.effectiveMode == target &&
                (target == .localWiFi ? local.hasLocalNetwork :
                    (snapshot?.verifies(target) == true && self.connectivityProber.probe(interfaceName: interface).routedInternetReady))
            let result = verified
                ? self.routeSafetyController.commit()
                : self.routeSafetyController.rollback()
            self.eventLogger.record(
                event: "route_transaction_recovered",
                detail: "\(verified ? "commit" : "rollback"): \(result.succeeded ? "success" : "failed")",
                candidateSSID: nil
            )
            if !result.succeeded {
                DispatchQueue.main.async {
                    self.requiresManualRecovery = true
                    self.errorMessage = "未完成的路由事务无法自动恢复"
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
