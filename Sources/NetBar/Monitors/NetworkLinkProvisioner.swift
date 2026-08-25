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

    private let runner: NetworkModeCommandRunning
    private let profile: MacMiniLinkProfile
    private let bundle: Bundle
    private let fileManager: FileManager
    private let pollAttempts: Int
    private let pollInterval: TimeInterval
    private let sleeper: (TimeInterval) -> Void
    private let backupDirectory: URL?

    init(
        runner: NetworkModeCommandRunning = DefaultNetworkModeCommandRunner(),
        profile: MacMiniLinkProfile = .bundled,
        bundle: Bundle = .module,
        fileManager: FileManager = .default,
        pollAttempts: Int = 60,
        pollInterval: TimeInterval = 2,
        backupDirectory: URL? = nil,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.runner = runner
        self.profile = profile
        self.bundle = bundle
        self.fileManager = fileManager
        self.pollAttempts = max(1, pollAttempts)
        self.pollInterval = max(0, pollInterval)
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

        if !remoteHelperStatus().succeeded {
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

        let remoteApply = runRemoteHelper("apply")
        guard remoteApply.succeeded else {
            return .init(
                kind: .failed,
                message: remoteApply.combinedMessage.isEmpty ? "Mac mini 固定链路配置失败" : remoteApply.combinedMessage
            )
        }

        let fixedConfiguration = NetworkServiceConfiguration(
            method: .manual,
            ipAddress: profile.localAddress,
            subnetMask: profile.subnetMask,
            router: profile.gatewayAddress,
            dnsServers: originalConfiguration.dnsServers
        )
        let localApply = runner.runPrivilegedNetworkConfiguration(
            serviceName: service.name,
            configuration: fixedConfiguration
        )
        guard localApply.succeeded else {
            let remoteRollback = runRemoteHelper("rollback")
            return .init(
                kind: remoteRollback.succeeded ? .failed : .recoveryRequired,
                message: localApply.combinedMessage.isEmpty ? "本机固定链路配置失败" : localApply.combinedMessage
            )
        }

        if verifyFixedLink() {
            return .init(kind: .success, message: "固定雷雳链路已初始化")
        }

        let rollbackConfiguration = (try? readLocalBackup()) ?? originalConfiguration
        let localRollback = runner.runPrivilegedNetworkConfiguration(
            serviceName: service.name,
            configuration: rollbackConfiguration
        )
        let remoteRollback = runRemoteHelper("rollback")
        let recoverySucceeded = localRollback.succeeded && remoteRollback.succeeded
        return .init(
            kind: recoverySucceeded ? .failed : .recoveryRequired,
            message: recoverySucceeded
                ? "固定链路验证失败，已恢复两端原配置"
                : "固定链路验证失败，且无法完整恢复两端配置"
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

    private func verifyRemoteIdentity() -> Bool {
        let result = runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: remoteHost(),
                remoteArguments: ["/usr/bin/true"]
            )
        )
        return result.succeeded
    }

    private func remoteHost() -> String {
        let ping = runner.run(
            executable: "/sbin/ping",
            arguments: ["-c", "1", "-W", "500", profile.gatewayAddress]
        )
        return ping.succeeded ? profile.gatewayAddress : profile.miniBonjourHost
    }

    private func runRemoteHelper(_ action: String) -> NetworkModeCommandResult {
        runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: remoteHost(),
                remoteArguments: ["/usr/bin/sudo", "-n", Self.miniHelperPath, action]
            )
        )
    }

    private func remoteHelperStatus() -> NetworkModeCommandResult {
        runRemoteHelper("status")
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
        ) else {
            return .init(kind: .failed, message: "NetBar 安装包缺少 Mini Helper 资源")
        }

        let remoteDirectory = "/tmp/netbar-mini-link-\(UUID().uuidString.lowercased())"
        let host = remoteHost()
        let mkdirResult = runner.run(
            executable: "/usr/bin/ssh",
            arguments: Self.sshArguments(
                profile: profile,
                host: host,
                remoteArguments: ["/bin/mkdir", "-p", remoteDirectory]
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
                helper.path, installer.path, profileURL.path, sudoers.path, destination
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
            if remoteHelperStatus().succeeded {
                return .init(kind: .success, message: "Mac mini Helper 已安装")
            }
            if attempt < pollAttempts - 1 {
                sleeper(pollInterval)
            }
        }
        return .init(kind: .failed, message: "等待 Mac mini 管理员授权超时，请完成终端中的安装后重试")
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
        directory.appendingPathComponent("thunderbolt-link-local-backup.json")
    }

    private func verifyFixedLink() -> Bool {
        let ifconfig = runner.run(executable: "/sbin/ifconfig", arguments: ["bridge0"])
        guard ifconfig.succeeded,
              LiveNetworkModeSystemProvider.parseInterfaceIPv4s(ifconfig.standardOutput).contains(profile.localAddress) else {
            return false
        }
        let ping = runner.run(
            executable: "/sbin/ping",
            arguments: ["-b", "bridge0", "-S", profile.localAddress, "-c", "1", "-W", "800", profile.gatewayAddress]
        )
        return ping.succeeded
    }
}
#endif
