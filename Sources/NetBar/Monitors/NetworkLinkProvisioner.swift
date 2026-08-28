import Foundation

enum NetworkLinkProvisioningOutcomeKind: Equatable {
    case success
    case failed
    case recoveryRequired
}

struct NetworkLinkProvisioningOutcome {
    let kind: NetworkLinkProvisioningOutcomeKind
    let message: String

    var succeeded: Bool { kind == .success }
}

protocol NetworkLinkProvisioning {
    func provision() -> NetworkLinkProvisioningOutcome
}

#if APP_STORE
final class NetworkLinkProvisioner: NetworkLinkProvisioning {
    init() {}

    func provision() -> NetworkLinkProvisioningOutcome {
        .init(kind: .failed, message: "App Store Lite 不支持链路初始化")
    }
}
#else
final class NetworkLinkProvisioner: NetworkLinkProvisioning {
    static let miniHelperPath = "/Library/PrivilegedHelperTools/com.zjah.NetBarMiniLinkHelper"
    static let miniHelperProtocolVersion = 5

    private let runner: NetworkModeCommandRunning
    private let profile: MacMiniLinkProfile
    private let bundle: Bundle
    private let fileManager: FileManager
    private let pollAttempts: Int
    private let pollInterval: TimeInterval
    private let verificationAttempts: Int
    private let verificationInterval: TimeInterval
    private let sleeper: (TimeInterval) -> Void
    private let backupDirectory: URL?

    init(
        runner: NetworkModeCommandRunning = DefaultNetworkModeCommandRunner(),
        profile: MacMiniLinkProfile = .bundled,
        bundle: Bundle = NetBarResourceBundle.current,
        fileManager: FileManager = .default,
        pollAttempts: Int = 60,
        pollInterval: TimeInterval = 2,
        verificationAttempts: Int = 12,
        verificationInterval: TimeInterval = 1,
        backupDirectory: URL? = nil,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.runner = runner
        self.profile = profile
        self.bundle = bundle
        self.fileManager = fileManager
        self.pollAttempts = max(1, pollAttempts)
        self.pollInterval = max(0, pollInterval)
        self.verificationAttempts = max(1, verificationAttempts)
        self.verificationInterval = max(0, verificationInterval)
        self.backupDirectory = backupDirectory
        self.sleeper = sleeper
    }

    func provision() -> NetworkLinkProvisioningOutcome {
        guard DistributionFlavor.current.supportsNetworkModeSwitch else {
            return .init(kind: .failed, message: "当前发行版本不支持网络配置")
        }

        let serviceResult = runner.run(
            executable: "/usr/sbin/networksetup",
            arguments: ["-listnetworkserviceorder"]
        )
        guard serviceResult.succeeded,
              let service = LiveNetworkModeSystemProvider
                .parseServiceOrder(serviceResult.standardOutput)
                .first(where: { $0.device == "bridge0" }) else {
            return .init(kind: .failed, message: "未发现雷雳网桥服务")
        }

        guard verifyKnownHost() else {
            return .init(kind: .failed, message: "Mac mini SSH 主机密钥缺失或不匹配，已拒绝初始化")
        }
        guard verifyRemoteIdentity() else {
            return .init(kind: .failed, message: "Mac mini SSH 主机密钥变化、身份验证失败或主机不可达，已拒绝初始化")
        }
        guard managementSubnetIsAvailable() else {
            return .init(kind: .failed, message: "本机已存在 10.254.254.0/30 地址或路由冲突，保持原配置")
        }

        if !Self.isCompatibleHelperStatus(remoteHelperStatus()) {
            let installResult = installRemoteHelper()
            guard installResult.succeeded else { return installResult }
        }

        let originalConfiguration: NetworkServiceConfiguration
        do {
            originalConfiguration = try readConfiguration(serviceName: service.name)
            try saveLocalBackupIfNeeded(originalConfiguration)
        } catch {
            return .init(kind: .failed, message: "保存本机网络配置失败：\(error.localizedDescription)")
        }

        let localAlias = runner.runPrivilegedEnsureManagementAlias(
            address: profile.managementLocalAddress,
            subnetMask: profile.managementSubnetMask
        )
        guard localAlias.succeeded else {
            return .init(
                kind: .failed,
                message: localAlias.combinedMessage.isEmpty ? "本机管理别名配置失败" : localAlias.combinedMessage
            )
        }

        let remotePrepare = runRemoteHelper("prepare")
        guard remotePrepare.succeeded else {
            _ = runner.runPrivilegedRemoveManagementAlias(address: profile.managementLocalAddress)
            return .init(
                kind: .failed,
                message: remotePrepare.combinedMessage.isEmpty ? "Mac mini 管理别名配置失败" : remotePrepare.combinedMessage
            )
        }

        guard verifyRemoteIdentity(host: profile.managementMiniAddress) else {
            let remoteRollback = runRemoteHelper("rollback")
            _ = runRemoteHelper("finalize-rollback")
            _ = runner.runPrivilegedRemoveManagementAlias(address: profile.managementLocalAddress)
            return .init(
                kind: remoteRollback.succeeded ? .failed : .recoveryRequired,
                message: "新管理地址 SSH 身份或连通性验证失败"
            )
        }

        let remoteMigrate = runRemoteHelper("migrate", host: profile.managementMiniAddress)
        guard remoteMigrate.succeeded || remoteManagementStatusIsConfigured() else {
            return rollbackAfterMigrationFailure(
                serviceName: service.name,
                originalConfiguration: originalConfiguration,
                reason: remoteMigrate.combinedMessage.isEmpty ? "Mac mini 地址面迁移失败" : remoteMigrate.combinedMessage
            )
        }

        let localApply = runner.runPrivilegedManagementMigration(
            serviceName: service.name,
            address: profile.managementLocalAddress,
            subnetMask: profile.managementSubnetMask,
            dnsServers: originalConfiguration.dnsServers
        )
        guard localApply.succeeded else {
            return rollbackAfterMigrationFailure(
                serviceName: service.name,
                originalConfiguration: originalConfiguration,
                reason: localApply.combinedMessage.isEmpty ? "本机地址面迁移失败" : localApply.combinedMessage
            )
        }

        if verifyManagementLink(serviceName: service.name) {
            return .init(kind: .success, message: "雷雳管理链路已迁移，数据面由 Apple DHCP 管理")
        }

        let rollbackConfiguration = (try? readLocalBackup()) ?? originalConfiguration
        let remoteRollback = runRemoteHelper("rollback")
        let localRollback = runner.runPrivilegedNetworkConfiguration(
            serviceName: service.name,
            configuration: rollbackConfiguration
        )
        let legacyVerified = remoteRollback.succeeded && verifyRollbackAccess(configuration: rollbackConfiguration)
        let remoteAliasRemoval = legacyVerified ? runRemoteHelper("finalize-rollback") : .init(
            exitCode: 1,
            standardOutput: "",
            standardError: "旧链路未验证，保留 Mini 管理别名"
        )
        let aliasRemoval = legacyVerified
            ? runner.runPrivilegedRemoveManagementAlias(address: profile.managementLocalAddress)
            : .init(exitCode: 1, standardOutput: "", standardError: "旧链路未验证，保留本机管理别名")
        let recoverySucceeded = localRollback.succeeded && remoteRollback.succeeded && legacyVerified &&
            remoteAliasRemoval.succeeded && aliasRemoval.succeeded
        return .init(
            kind: recoverySucceeded ? .failed : .recoveryRequired,
            message: recoverySucceeded
                ? "管理链路验证失败，已恢复两端原配置"
                : "管理链路验证失败，且无法完整恢复两端配置"
        )
    }

    static func parseConfiguration(info: String, dnsOutput: String) -> NetworkServiceConfiguration {
        let method: NetworkConfigurationMethod = info.contains("Manual Configuration") ? .manual : .dhcp
        let dnsServers: [String]
        if dnsOutput.contains("There aren't any DNS Servers") {
            dnsServers = []
        } else {
            dnsServers = dnsOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return NetworkServiceConfiguration(
            method: method,
            ipAddress: LiveNetworkModeSystemProvider.parseNetworkInfoValue("IP address", from: info),
            subnetMask: LiveNetworkModeSystemProvider.parseNetworkInfoValue("Subnet mask", from: info),
            router: LiveNetworkModeSystemProvider.parseNetworkInfoValue("Router", from: info),
            dnsServers: dnsServers
        )
    }

    static func isCompatibleHelperStatus(_ result: NetworkModeCommandResult) -> Bool {
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["protocolVersion"] as? Int else {
            return false
        }
        return version == miniHelperProtocolVersion
    }

    static func hasManagementSubnetConflict(
        ifconfigOutput: String,
        routeOutput: String,
        allowedAddress: String
    ) -> Bool {
        var interface = ""
        for rawLine in ifconfigOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !rawLine.hasPrefix("\t"), let colon = line.firstIndex(of: ":") {
                interface = String(line[..<colon])
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.count >= 2, fields[0] == "inet", fields[1].hasPrefix("10.254.254.") {
                if interface != "bridge0" || fields[1] != allowedAddress { return true }
            }
        }
        for rawLine in routeOutput.components(separatedBy: .newlines) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let destination = fields.first else { continue }
            let targetsManagementSubnet = destination == "10.254.254/30" ||
                destination == "10.254.254.0/30" || destination == "10.254.254"
            if targetsManagementSubnet && fields.last != "bridge0" { return true }
        }
        return false
    }

    static func sshArguments(profile: MacMiniLinkProfile, host: String, remoteArguments: [String]) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlias=\(profile.fixedHostKeyAlias)",
            "\(profile.miniSSHUser)@\(host)"
        ] + remoteArguments
    }

    private func verifyKnownHost() -> Bool {
        let result = runner.run(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-F", profile.fixedHostKeyAlias]
        )
        return result.succeeded && !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func managementSubnetIsAvailable() -> Bool {
        let interfaces = runner.run(executable: "/sbin/ifconfig", arguments: ["-a"])
        let routes = runner.run(executable: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        guard interfaces.succeeded, routes.succeeded else { return false }
        return !Self.hasManagementSubnetConflict(
            ifconfigOutput: interfaces.standardOutput,
            routeOutput: routes.standardOutput,
            allowedAddress: profile.managementLocalAddress
        )
    }

    private func verifyRemoteIdentity(host: String? = nil) -> Bool {
        let result = runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: host ?? remoteHost(),
                remoteArguments: ["/usr/bin/true"]
            )
        )
        return result.succeeded
    }

    private func remoteHost() -> String {
        let managementPing = runner.run(
            executable: "/sbin/ping",
            arguments: ["-c", "1", "-W", "500", profile.managementMiniAddress]
        )
        if managementPing.succeeded { return profile.managementMiniAddress }
        let legacyPing = runner.run(
            executable: "/sbin/ping",
            arguments: ["-c", "1", "-W", "500", profile.sshHostKeyAlias]
        )
        return legacyPing.succeeded ? profile.sshHostKeyAlias : profile.miniBonjourHost
    }

    private func runRemoteHelper(_ action: String, host: String? = nil) -> NetworkModeCommandResult {
        runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: host ?? remoteHost(),
                remoteArguments: ["/usr/bin/sudo", "-n", Self.miniHelperPath, action]
            )
        )
    }

    private func remoteHelperStatus() -> NetworkModeCommandResult {
        runRemoteHelper("status")
    }

    private func rollbackAfterMigrationFailure(
        serviceName: String,
        originalConfiguration: NetworkServiceConfiguration,
        reason: String
    ) -> NetworkLinkProvisioningOutcome {
        let remoteRollback = runRemoteHelper("rollback", host: profile.managementMiniAddress)
        let localRollback = runner.runPrivilegedNetworkConfiguration(
            serviceName: serviceName,
            configuration: originalConfiguration
        )
        let legacyVerified = remoteRollback.succeeded && localRollback.succeeded &&
            verifyRollbackAccess(configuration: originalConfiguration)
        let remoteAliasRemoval = legacyVerified ? runRemoteHelper("finalize-rollback") : .init(
            exitCode: 1,
            standardOutput: "",
            standardError: "旧链路未验证，保留 Mini 管理别名"
        )
        let localAliasRemoval = legacyVerified
            ? runner.runPrivilegedRemoveManagementAlias(address: profile.managementLocalAddress)
            : .init(exitCode: 1, standardOutput: "", standardError: "旧链路未验证，保留本机管理别名")
        let recovered = remoteRollback.succeeded && localRollback.succeeded && legacyVerified &&
            remoteAliasRemoval.succeeded && localAliasRemoval.succeeded
        return .init(
            kind: recovered ? .failed : .recoveryRequired,
            message: recovered ? "\(reason)；已恢复并验证旧链路" : "\(reason)；自动回滚不完整，已保留管理别名"
        )
    }

    private func verifyRollbackAccess(configuration: NetworkServiceConfiguration) -> Bool {
        if configuration.method == .manual,
           configuration.router == profile.sshHostKeyAlias || configuration.ipAddress != nil {
            return verifyRemoteIdentity(host: profile.sshHostKeyAlias)
        }
        return verifyRemoteIdentity(host: profile.miniBonjourHost)
    }

    private func remoteManagementStatusIsConfigured() -> Bool {
        let result = remoteHelperStatus()
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let status = try? JSONDecoder().decode(MacMiniHelperStatus.self, from: data) else {
            return false
        }
        return status.protocolVersion == Self.miniHelperProtocolVersion && status.configured && status.bridgeUsesDHCP
    }

    private func installRemoteHelper() -> NetworkLinkProvisioningOutcome {
        guard let helper = bundle.url(
            forResource: "netbar-mini-link-helper",
            withExtension: nil,
            subdirectory: "MiniLinkHelper"
        ),
        let installer = bundle.url(
            forResource: "install-netbar-mini-link-helper",
            withExtension: "command",
            subdirectory: "MiniLinkHelper"
        ),
        let profileURL = bundle.url(
            forResource: "MacMiniLinkProfile",
            withExtension: "plist",
            subdirectory: "MiniLinkHelper"
        ),
        let sudoers = bundle.url(
            forResource: "com.zjah.NetBarMiniLinkHelper",
            withExtension: "sudoers",
            subdirectory: "MiniLinkHelper"
        ),
        let guardianPlist = bundle.url(
            forResource: "com.zjah.NetBarMiniNetworkGuardian",
            withExtension: "plist",
            subdirectory: "MiniLinkHelper"
        ),
        let guardian = guardianExecutableURL() else {
            return .init(kind: .failed, message: "NetBar 安装包缺少 Mini Helper 资源")
        }

        let remoteDirectory = "/tmp/netbar-mini-link-\(UUID().uuidString.lowercased())"
        let host = remoteHost()
        let mkdirResult = runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: host,
                remoteArguments: ["/bin/mkdir", "-m", "0700", remoteDirectory]
            )
        )
        guard mkdirResult.succeeded else {
            return .init(kind: .failed, message: mkdirResult.combinedMessage)
        }

        let destination = "\(profile.miniSSHUser)@\(host):\(remoteDirectory)/"
        let copyResult = runner.run(
            executable: "/usr/bin/scp",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "HostKeyAlias=\(profile.fixedHostKeyAlias)",
                helper.path, installer.path, profileURL.path, sudoers.path,
                guardian.path, guardianPlist.path, destination
            ]
        )
        guard copyResult.succeeded else {
            return .init(kind: .failed, message: copyResult.combinedMessage)
        }

        let remoteInstaller = "\(remoteDirectory)/install-netbar-mini-link-helper.command"
        let chmodResult = runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: host,
                remoteArguments: ["/bin/chmod", "0755", remoteInstaller]
            )
        )
        guard chmodResult.succeeded else {
            return .init(kind: .failed, message: chmodResult.combinedMessage)
        }

        let openResult = runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: host,
                remoteArguments: ["/usr/bin/open", "-a", "Terminal", remoteInstaller]
            )
        )
        guard openResult.succeeded else {
            return .init(kind: .failed, message: "无法在 Mac mini 打开 Helper 安装终端")
        }

        for attempt in 0..<pollAttempts {
            if Self.isCompatibleHelperStatus(remoteHelperStatus()) {
                return .init(kind: .success, message: "Mac mini Helper 已安装")
            }
            if attempt < pollAttempts - 1 {
                sleeper(pollInterval)
            }
        }
        return .init(kind: .failed, message: "等待 Mac mini 管理员授权超时，请完成终端中的安装后重试")
    }

    private func guardianExecutableURL() -> URL? {
        if let bundled = bundle.url(
            forResource: "NetBarMiniNetworkGuardian",
            withExtension: nil,
            subdirectory: "MiniLinkHelper"
        ) {
            return bundled
        }
        let executableSibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("NetBarMiniNetworkGuardian")
        return fileManager.isExecutableFile(atPath: executableSibling.path) ? executableSibling : nil
    }

    private func readConfiguration(serviceName: String) throws -> NetworkServiceConfiguration {
        let info = runner.run(
            executable: "/usr/sbin/networksetup",
            arguments: ["-getinfo", serviceName]
        )
        let dns = runner.run(
            executable: "/usr/sbin/networksetup",
            arguments: ["-getdnsservers", serviceName]
        )
        guard info.succeeded, dns.succeeded else {
            throw NetworkModeSystemError.commandFailed([info.combinedMessage, dns.combinedMessage].joined(separator: "\n"))
        }
        return Self.parseConfiguration(info: info.standardOutput, dnsOutput: dns.standardOutput)
    }

    private func saveLocalBackupIfNeeded(_ configuration: NetworkServiceConfiguration) throws {
        let directory = try resolvedBackupDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = localBackupURL(in: directory)
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: backupURL, options: .atomic)
    }

    private func readLocalBackup() throws -> NetworkServiceConfiguration {
        let data = try Data(contentsOf: localBackupURL(in: try resolvedBackupDirectory()))
        return try JSONDecoder().decode(NetworkServiceConfiguration.self, from: data)
    }

    private func resolvedBackupDirectory() throws -> URL {
        if let backupDirectory { return backupDirectory }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("NetBar", isDirectory: true)
    }

    private func localBackupURL(in directory: URL) -> URL {
        directory.appendingPathComponent("thunderbolt-address-plane-v5-backup.json")
    }

    private func verifyManagementLink(serviceName: String) -> Bool {
        for attempt in 0..<verificationAttempts {
            let ifconfig = runner.run(executable: "/sbin/ifconfig", arguments: ["bridge0"])
            if ifconfig.succeeded,
               LiveNetworkModeSystemProvider.parseInterfaceIPv4s(ifconfig.standardOutput).contains(profile.managementLocalAddress) {
                let info = runner.run(
                    executable: "/usr/sbin/networksetup",
                    arguments: ["-getinfo", serviceName]
                )
                let ping = runner.run(
                    executable: "/sbin/ping",
                    arguments: [
                        "-b", "bridge0", "-S", profile.managementLocalAddress,
                        "-c", "1", "-W", "800", profile.managementMiniAddress
                    ]
                )
                if info.standardOutput.contains("DHCP Configuration") && ping.succeeded { return true }
            }
            if attempt < verificationAttempts - 1 {
                sleeper(verificationInterval)
            }
        }
        return false
    }
}
#endif
