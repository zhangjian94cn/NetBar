import Foundation
import XCTest
@testable import NetBar

final class NetworkStaticLinkTests: XCTestCase {
    func testLiveSnapshotDistinguishesFixedLinkAndBoundGateway() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1"
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.linkState, .connected)
        XCTAssertEqual(snapshot.gatewayState, .ready)
        XCTAssertEqual(snapshot.bridgeIPv4, "192.168.2.2")
        XCTAssertTrue(runner.invocations.contains { invocation in
            invocation.executable == "/sbin/ping" &&
                invocation.arguments.prefix(4) == ["-b", "bridge0", "-S", "192.168.2.2"]
        })
    }

    func testLiveSnapshotTreatsLinkLocalWrongAndMissingAddressAsNotProvisioned() throws {
        for address in ["169.254.4.8", "192.168.3.2", nil] {
            let runner = SnapshotCommandRunner(
                bridgeOutput: Self.bridge(address: address, active: true),
                router: address == nil ? nil : "192.168.2.1"
            )

            let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

            XCTAssertEqual(snapshot.linkState, .addressNotProvisioned, "address: \(address ?? "nil")")
            XCTAssertEqual(snapshot.gatewayState, .unknown)
        }
    }

    func testLiveSnapshotTreatsCorrectDHCPLeaseAsNotProvisioned() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            manualConfiguration: false
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.linkState, .addressNotProvisioned)
        XCTAssertEqual(snapshot.gatewayState, .unknown)
    }

    func testLiveSnapshotReportsNoCarrierAndUnreachablePeer() throws {
        let inactive = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: false),
            router: "192.168.2.1"
        )
        XCTAssertEqual(
            try LiveNetworkModeSystemProvider(commandRunner: inactive).readSnapshot().linkState,
            .disconnected
        )

        let unreachable = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            peerReachable: false
        )
        XCTAssertEqual(
            try LiveNetworkModeSystemProvider(commandRunner: unreachable).readSnapshot().linkState,
            .miniUnreachable
        )
    }

    func testLiveSnapshotDoesNotUseVPNReachabilityForMiniUpstream() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            boundEgressReachable: false
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.linkState, .connected)
        XCTAssertEqual(snapshot.gatewayState, .upstreamUnavailable)
    }

    func testConfigurationParserPreservesDHCPManualAndDNS() {
        let dhcp = NetworkLinkProvisioner.parseConfiguration(
            info: "DHCP Configuration\nIP address: 169.254.2.4\nSubnet mask: 255.255.0.0\nRouter: none",
            dnsOutput: "There aren't any DNS Servers set on Thunderbolt Bridge."
        )
        XCTAssertEqual(dhcp.method, .dhcp)
        XCTAssertEqual(dhcp.ipAddress, "169.254.2.4")
        XCTAssertTrue(dhcp.dnsServers.isEmpty)

        let manual = NetworkLinkProvisioner.parseConfiguration(
            info: "Manual Configuration\nIP address: 192.168.9.2\nSubnet mask: 255.255.255.0\nRouter: 192.168.9.1",
            dnsOutput: "1.1.1.1\n114.114.114.114\n"
        )
        XCTAssertEqual(manual.method, .manual)
        XCTAssertEqual(manual.router, "192.168.9.1")
        XCTAssertEqual(manual.dnsServers, ["1.1.1.1", "114.114.114.114"])
    }

    func testSSHArgumentsRequireRegisteredHostIdentity() {
        let arguments = NetworkLinkProvisioner.sshArguments(
            profile: .defaults,
            host: "zhangjiandemac-mini.local",
            remoteArguments: ["/usr/bin/true"]
        )

        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("HostKeyAlias=192.168.2.1"))
        XCTAssertFalse(arguments.contains("StrictHostKeyChecking=no"))
    }

    func testProvisionerRefusesMissingOrChangedHostIdentity() throws {
        let missing = ProvisioningCommandRunner()
        missing.knownHostAvailable = false
        let missingOutcome = makeProvisioner(runner: missing).provision()
        XCTAssertEqual(missingOutcome.kind, .failed)
        XCTAssertTrue(missingOutcome.message.contains("主机密钥缺失"))
        XCTAssertTrue(missing.privilegedConfigurations.isEmpty)

        let changed = ProvisioningCommandRunner()
        changed.remoteIdentityValid = false
        let changedOutcome = makeProvisioner(runner: changed).provision()
        XCTAssertEqual(changedOutcome.kind, .failed)
        XCTAssertTrue(changedOutcome.message.contains("主机密钥变化"))
        XCTAssertTrue(changed.privilegedConfigurations.isEmpty)
    }

    func testProvisionerSuccessIsIdempotentAndKeepsOriginalBackup() throws {
        let runner = ProvisioningCommandRunner()
        let directory = temporaryDirectory()
        let provisioner = makeProvisioner(runner: runner, backupDirectory: directory)

        XCTAssertEqual(provisioner.provision().kind, .success)
        runner.localInfo = "Manual Configuration\nIP address: 192.168.2.2\nSubnet mask: 255.255.255.0\nRouter: 192.168.2.1"
        XCTAssertEqual(provisioner.provision().kind, .success)

        let backupData = try Data(contentsOf: directory.appendingPathComponent("thunderbolt-link-local-backup.json"))
        let backup = try JSONDecoder().decode(NetworkServiceConfiguration.self, from: backupData)
        XCTAssertEqual(backup.method, .dhcp)
        XCTAssertEqual(runner.privilegedConfigurations.count, 2)
        XCTAssertTrue(runner.privilegedConfigurations.allSatisfy { $0.configuration.method == .manual })
    }

    func testProvisionerRollsBackBothEndsAndUsesSavedOriginalConfiguration() throws {
        let runner = ProvisioningCommandRunner()
        runner.fixedLinkVerificationSucceeds = false
        let outcome = makeProvisioner(
            runner: runner,
            backupDirectory: temporaryDirectory()
        ).provision()

        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertTrue(outcome.message.contains("已恢复两端原配置"))
        XCTAssertEqual(runner.privilegedConfigurations.map(\.configuration.method), [.manual, .dhcp])
        XCTAssertTrue(runner.remoteActions.contains("rollback"))
    }

    func testProvisionerReportsRecoveryRequiredWhenRollbackFails() {
        let runner = ProvisioningCommandRunner()
        runner.localApplySucceeds = false
        runner.remoteRollbackSucceeds = false

        let outcome = makeProvisioner(runner: runner).provision()

        XCTAssertEqual(outcome.kind, .recoveryRequired)
        XCTAssertTrue(outcome.message.contains("本机固定链路配置失败"))
    }

    func testMiniHelperRejectsUnknownCommandsAndHasExactSudoersContract() throws {
        let bundle = Bundle.module
        let helper = try XCTUnwrap(bundle.url(
            forResource: "netbar-mini-link-helper",
            withExtension: nil,
            subdirectory: "MiniLinkHelper"
        ))
        let installer = try XCTUnwrap(bundle.url(
            forResource: "install-netbar-mini-link-helper",
            withExtension: "command",
            subdirectory: "MiniLinkHelper"
        ))
        let sudoers = try XCTUnwrap(bundle.url(
            forResource: "com.zjah.NetBarMiniLinkHelper",
            withExtension: "sudoers",
            subdirectory: "MiniLinkHelper"
        ))

        XCTAssertNotEqual(run("/bin/zsh", [helper.path, "arbitrary"]).exitCode, 0)
        XCTAssertNotEqual(run("/bin/zsh", [helper.path, "status", "extra"]).exitCode, 0)

        let installerSource = try String(contentsOf: installer)
        let sudoersSource = try String(contentsOf: sudoers)
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper status"))
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper apply"))
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper rollback"))
        XCTAssertFalse(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper *"))
        XCTAssertTrue(installerSource.contains("visudo -cf"))
    }

    private func makeProvisioner(
        runner: ProvisioningCommandRunner,
        backupDirectory: URL? = nil
    ) -> NetworkLinkProvisioner {
        NetworkLinkProvisioner(
            runner: runner,
            profile: .defaults,
            bundle: .module,
            pollAttempts: 2,
            pollInterval: 0,
            backupDirectory: backupDirectory ?? temporaryDirectory(),
            sleeper: { _ in }
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func run(_ executable: String, _ arguments: [String]) -> NetworkModeCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            return .init(
                exitCode: process.terminationStatus,
                standardOutput: "",
                standardError: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        } catch {
            return .init(exitCode: -1, standardOutput: "", standardError: error.localizedDescription)
        }
    }

    private static func bridge(address: String?, active: Bool) -> String {
        var lines = ["bridge0: flags=8863<UP,RUNNING>"]
        if let address { lines.append("\tinet \(address) netmask 0xffffff00") }
        lines.append("\tstatus: \(active ? "active" : "inactive")")
        return lines.joined(separator: "\n")
    }
}

private final class SnapshotCommandRunner: NetworkModeCommandRunning {
    struct Invocation {
        let executable: String
        let arguments: [String]
    }

    let bridgeOutput: String
    let router: String?
    let peerReachable: Bool
    let boundEgressReachable: Bool
    let manualConfiguration: Bool
    private(set) var invocations: [Invocation] = []

    init(
        bridgeOutput: String,
        router: String?,
        peerReachable: Bool = true,
        boundEgressReachable: Bool = true,
        manualConfiguration: Bool = true
    ) {
        self.bridgeOutput = bridgeOutput
        self.router = router
        self.peerReachable = peerReachable
        self.boundEgressReachable = boundEgressReachable
        self.manualConfiguration = manualConfiguration
    }

    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        invocations.append(.init(executable: executable, arguments: arguments))
        if executable == "/usr/sbin/networksetup", arguments == ["-listnetworkserviceorder"] {
            return .success(Self.serviceOrder)
        }
        if executable == "/sbin/ifconfig" { return .success(bridgeOutput) }
        if executable == "/usr/sbin/networksetup", arguments.first == "-getinfo" {
            let method = manualConfiguration ? "Manual Configuration" : "DHCP Configuration"
            return .success("\(method)\nIP address: 192.168.2.2\nSubnet mask: 255.255.255.0\nRouter: \(router ?? "none")")
        }
        if executable == "/sbin/route" { return .success("interface: en0") }
        if executable == "/sbin/ping" {
            if arguments.last == "192.168.2.1" { return peerReachable ? .success() : .failure("timeout") }
            return boundEgressReachable ? .success() : .failure("timeout")
        }
        return .failure("unexpected command: \(executable) \(arguments)")
    }

    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult { .success() }

    private static let serviceOrder = """
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)
    (2) Thunderbolt Bridge
    (Hardware Port: Thunderbolt Bridge, Device: bridge0)
    """
}

private final class ProvisioningCommandRunner: NetworkModeCommandRunning {
    var knownHostAvailable = true
    var remoteIdentityValid = true
    var remoteHelperInstalled = true
    var localApplySucceeds = true
    var remoteRollbackSucceeds = true
    var fixedLinkVerificationSucceeds = true
    var localInfo = "DHCP Configuration\nIP address: 169.254.2.4\nSubnet mask: 255.255.0.0\nRouter: none"
    private(set) var privilegedConfigurations: [(serviceName: String, configuration: NetworkServiceConfiguration)] = []
    private(set) var remoteActions: [String] = []

    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        if executable == "/usr/sbin/networksetup", arguments == ["-listnetworkserviceorder"] {
            return .success("""
            (1) Wi-Fi
            (Hardware Port: Wi-Fi, Device: en0)
            (2) Thunderbolt Bridge
            (Hardware Port: Thunderbolt Bridge, Device: bridge0)
            """)
        }
        if executable == "/usr/bin/ssh-keygen" {
            return knownHostAvailable ? .success("192.168.2.1 ssh-ed25519 AAAA") : .failure("not found")
        }
        if executable == "/sbin/ping" {
            if arguments.contains("-b") {
                return fixedLinkVerificationSucceeds ? .success() : .failure("timeout")
            }
            return .success()
        }
        if executable == "/usr/bin/ssh" {
            if arguments.last == "/usr/bin/true" {
                return remoteIdentityValid ? .success() : .failure("REMOTE HOST IDENTIFICATION HAS CHANGED")
            }
            if let action = arguments.last, ["status", "apply", "rollback"].contains(action) {
                remoteActions.append(action)
                if action == "status" { return remoteHelperInstalled ? .success("{}") : .failure("missing") }
                if action == "rollback" { return remoteRollbackSucceeds ? .success("{}") : .failure("rollback failed") }
                return .success("{}")
            }
            return .success()
        }
        if executable == "/usr/sbin/networksetup", arguments.first == "-getinfo" {
            return .success(localInfo)
        }
        if executable == "/usr/sbin/networksetup", arguments.first == "-getdnsservers" {
            return .success("There aren't any DNS Servers set on Thunderbolt Bridge.")
        }
        if executable == "/sbin/ifconfig" {
            return fixedLinkVerificationSucceeds
                ? .success("inet 192.168.2.2 netmask 0xffffff00\nstatus: active")
                : .success("inet 169.254.2.4 netmask 0xffff0000\nstatus: active")
        }
        return .failure("unexpected command: \(executable) \(arguments)")
    }

    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult { .success() }

    func runPrivilegedNetworkConfiguration(
        serviceName: String,
        configuration: NetworkServiceConfiguration
    ) -> NetworkModeCommandResult {
        privilegedConfigurations.append((serviceName, configuration))
        return localApplySucceeds ? .success() : .failure("本机固定链路配置失败")
    }
}

private extension NetworkModeCommandResult {
    static func success(_ output: String = "") -> NetworkModeCommandResult {
        .init(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(_ message: String) -> NetworkModeCommandResult {
        .init(exitCode: 1, standardOutput: "", standardError: message)
    }
}
