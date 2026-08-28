import Foundation
import XCTest
@testable import NetBar

final class NetworkStaticLinkTests: XCTestCase {
    func testInstalledAppResolvesSwiftPMResourceBundleFromContentsResources() throws {
        let appURL = temporaryDirectory().appendingPathComponent("NetBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let installedBundleURL = resourcesURL.appendingPathComponent(
            "NetBar_NetBar.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Bundle.module.bundleURL, to: installedBundleURL)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.zjah.NetBar.ResourceResolutionTest",
            "CFBundleName": "NetBar",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let appBundle = try XCTUnwrap(Bundle(url: appURL))
        let resolved = try XCTUnwrap(NetBarResourceBundle.installedBundle(in: appBundle))
        XCTAssertEqual(resolved.bundleURL.standardizedFileURL, installedBundleURL.standardizedFileURL)
        XCTAssertNotNil(resolved.url(
            forResource: "netbar-mini-link-helper",
            withExtension: nil,
            subdirectory: "MiniLinkHelper"
        ))
    }

    func testLiveSnapshotSeparatesManagementAliasFromAppleDHCPGateway() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1"
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.linkState, .connected)
        XCTAssertEqual(snapshot.gatewayState, .ready)
        XCTAssertEqual(snapshot.bridgeIPv4, "192.168.2.2")
        XCTAssertEqual(snapshot.miniGateway, "192.168.2.1")
        XCTAssertTrue(runner.invocations.contains { invocation in
            invocation.executable == "/usr/bin/curl" &&
                invocation.arguments.contains("--interface") &&
                invocation.arguments.contains("bridge0") &&
                invocation.arguments.contains("--noproxy")
        })
    }

    func testLiveSnapshotUsesDHCPLeaseWhenOldAndNewSharingAddressesCoexist() throws {
        let bridge = """
        bridge0: flags=8863<UP,RUNNING>
            inet 10.254.254.2 netmask 0xfffffffc
            inet 192.168.2.2 netmask 0xffffff00
            inet 192.168.3.2 netmask 0xffffff00
            status: active
        """
        let runner = SnapshotCommandRunner(
            bridgeOutput: bridge,
            router: "192.168.3.1",
            serviceAddress: "192.168.3.2"
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.bridgeIPv4, "192.168.3.2")
        XCTAssertEqual(snapshot.miniGateway, "192.168.3.1")
        XCTAssertEqual(snapshot.gatewayState, .ready)
    }

    func testLiveSnapshotRejectsMissingManagementAlias() throws {
        for address in ["169.254.4.8", "192.168.3.2", nil] {
            let runner = SnapshotCommandRunner(
                bridgeOutput: Self.bridge(address: address, active: true, includeManagement: false),
                router: address == nil ? nil : "192.168.2.1"
            )

            let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

            XCTAssertEqual(snapshot.linkState, .addressNotProvisioned, "address: \(address ?? "nil")")
            XCTAssertEqual(snapshot.gatewayState, .unknown)
        }
    }

    func testLiveSnapshotRejectsManualConfigurationEvenWithBothAddresses() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            manualConfiguration: true
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.linkState, .addressNotProvisioned)
        XCTAssertEqual(snapshot.gatewayState, .unknown)
    }

    func testLiveSnapshotDoesNotCoupleSplitLinkReadinessToDNSChoice() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            dnsConfigured: false
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.linkState, .connected)
        XCTAssertEqual(snapshot.gatewayState, .ready)
        XCTAssertFalse(runner.invocations.contains { invocation in
            invocation.executable == "/usr/sbin/networksetup" &&
                invocation.arguments.first == "-getdnsservers"
        })
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
        XCTAssertEqual(snapshot.gatewayState, .remoteStatusUnavailable)
    }

    func testLiveSnapshotAcceptsOneReachableBoundHTTPSProbeTargetAndIgnoresICMP() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            reachableProbeTargets: ["https://www.apple.com/library/test/success.html"]
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.gatewayState, .ready)
        XCTAssertFalse(runner.invocations.contains { invocation in
            invocation.executable == "/sbin/ping" && invocation.arguments.last != "10.254.254.1"
        })
    }

    func testRemoteReadyQualifiesTransactionalTrialWhenDirectBypassIsRestricted() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            boundEgressReachable: false,
            remoteHelperJSON: Self.readyHelperJSON
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.gatewayState, .ready)
    }

    func testLiveSnapshotUsesNWIPhysicalInterfaceWhenDefaultRouteIsUTUN() throws {
        let runner = SnapshotCommandRunner(
            bridgeOutput: Self.bridge(address: "192.168.2.2", active: true),
            router: "192.168.2.1",
            defaultRouteInterface: "utun6",
            nwiPrimaryInterface: "bridge0"
        )

        let snapshot = try LiveNetworkModeSystemProvider(commandRunner: runner).readSnapshot()

        XCTAssertEqual(snapshot.physicalDefaultInterface, "bridge0")
        XCTAssertEqual(snapshot.effectiveMode, .macMiniGateway)
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

    func testProvisionerRejectsMissingMalformedAndOldHelperProtocol() {
        XCTAssertFalse(NetworkLinkProvisioner.isCompatibleHelperStatus(.failure("missing")))
        XCTAssertFalse(NetworkLinkProvisioner.isCompatibleHelperStatus(.success("{}")))
        XCTAssertFalse(NetworkLinkProvisioner.isCompatibleHelperStatus(.success(
            "{\"protocolVersion\":4}"
        )))
        XCTAssertTrue(NetworkLinkProvisioner.isCompatibleHelperStatus(.success(
            "{\"protocolVersion\":5}"
        )))
    }

    func testManagementSubnetPreflightRejectsForeignAddressAndRoute() {
        XCTAssertTrue(NetworkLinkProvisioner.hasManagementSubnetConflict(
            ifconfigOutput: "en7: flags=8863<UP,RUNNING>\n\tinet 10.254.254.3 netmask 0xfffffffc",
            routeOutput: "Routing tables",
            allowedAddress: "10.254.254.2"
        ))
        XCTAssertTrue(NetworkLinkProvisioner.hasManagementSubnetConflict(
            ifconfigOutput: "bridge0: flags=8863<UP,RUNNING>\n\tinet 10.254.254.2 netmask 0xfffffffc",
            routeOutput: "10.254.254/30  192.0.2.1  UGSc  en7",
            allowedAddress: "10.254.254.2"
        ))
        XCTAssertFalse(NetworkLinkProvisioner.hasManagementSubnetConflict(
            ifconfigOutput: "bridge0: flags=8863<UP,RUNNING>\n\tinet 10.254.254.2 netmask 0xfffffffc",
            routeOutput: "10.254.254/30  link#22  UCS  bridge0",
            allowedAddress: "10.254.254.2"
        ))
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
        runner.localInfo = "DHCP Configuration\nIP address: 192.168.3.2\nSubnet mask: 255.255.255.0\nRouter: 192.168.3.1"
        XCTAssertEqual(provisioner.provision().kind, .success)

        let backupData = try Data(contentsOf: directory.appendingPathComponent("thunderbolt-address-plane-v5-backup.json"))
        let backup = try JSONDecoder().decode(NetworkServiceConfiguration.self, from: backupData)
        XCTAssertEqual(backup.method, .dhcp)
        XCTAssertEqual(runner.privilegedConfigurations.count, 2)
        XCTAssertTrue(runner.privilegedConfigurations.allSatisfy { $0.configuration.method == .dhcp })
        XCTAssertTrue(runner.privilegedConfigurations.allSatisfy { $0.configuration.dnsServers.isEmpty })
    }

    func testProvisionerPreservesExistingThunderboltDNSInsteadOfForcingMiniResolver() {
        let runner = ProvisioningCommandRunner()
        runner.localDNSOutput = "1.1.1.1\n114.114.114.114"
        let outcome = makeProvisioner(runner: runner, backupDirectory: temporaryDirectory()).provision()

        XCTAssertEqual(outcome.kind, .success)
        XCTAssertEqual(runner.privilegedConfigurations.first?.configuration.dnsServers, ["1.1.1.1", "114.114.114.114"])
        XCTAssertFalse(runner.privilegedConfigurations.contains { $0.configuration.dnsServers == ["192.168.2.1"] })
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
        XCTAssertEqual(runner.privilegedConfigurations.map(\.configuration.method), [.dhcp, .dhcp])
        XCTAssertTrue(runner.remoteActions.contains("rollback"))
    }

    func testProvisionerWaitsForAddressAndPeerToSettle() {
        let runner = ProvisioningCommandRunner()
        runner.addressVerificationFailuresRemaining = 1
        runner.pingVerificationFailuresRemaining = 1

        let outcome = makeProvisioner(runner: runner).provision()

        XCTAssertEqual(outcome.kind, .success)
        XCTAssertEqual(runner.addressVerificationChecks, 3)
        XCTAssertEqual(runner.pingVerificationChecks, 2)
        XCTAssertFalse(runner.remoteActions.contains("rollback"))
    }

    func testProvisionerReportsRecoveryRequiredWhenRollbackFails() {
        let runner = ProvisioningCommandRunner()
        runner.localApplySucceeds = false
        runner.remoteRollbackSucceeds = false

        let outcome = makeProvisioner(runner: runner).provision()

        XCTAssertEqual(outcome.kind, .recoveryRequired)
        XCTAssertTrue(outcome.message.contains("本机地址面迁移失败"))
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
        let guardianPlist = try XCTUnwrap(bundle.url(
            forResource: "com.zjah.NetBarMiniNetworkGuardian",
            withExtension: "plist",
            subdirectory: "MiniLinkHelper"
        ))

        XCTAssertNotEqual(run("/bin/zsh", [helper.path, "arbitrary"]).exitCode, 0)
        XCTAssertNotEqual(run("/bin/zsh", [helper.path, "status", "extra"]).exitCode, 0)

        let installerSource = try String(contentsOf: installer)
        let helperSource = try String(contentsOf: helper)
        let sudoersSource = try String(contentsOf: sudoers)
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper status"))
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper prepare"))
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper migrate"))
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper rollback"))
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper finalize-rollback"))
        XCTAssertTrue(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper report-egress-failure"))
        XCTAssertFalse(sudoersSource.contains("com.zjah.NetBarMiniLinkHelper *"))
        XCTAssertTrue(installerSource.contains("visudo -cf"))
        XCTAssertTrue(installerSource.contains(
            "SUDOERS_TARGET=/etc/sudoers.d/netbar-mini-link-helper"
        ))
        XCTAssertTrue(installerSource.contains(
            "LEGACY_SUDOERS_TARGET=/etc/sudoers.d/com.zjah.NetBarMiniLinkHelper"
        ))
        XCTAssertTrue(installerSource.contains("/bin/rm -f \"$LEGACY_SUDOERS_TARGET\""))
        XCTAssertTrue(helperSource.contains("NAT.SharingDevices.$index"))
        XCTAssertFalse(helperSource.contains("NAT.SharingDevices json"))
        XCTAssertTrue(helperSource.contains("protocolVersion\\\":5"))
        XCTAssertTrue(helperSource.contains("system/com.apple.NetworkSharing"))
        XCTAssertTrue(helperSource.contains("net.inet.ip.forwarding"))
        XCTAssertTrue(helperSource.contains("evidenceConflict"))
        XCTAssertTrue(helperSource.contains("hotspotAPActive"))
        XCTAssertTrue(helperSource.contains("hotspotClientObserved"))
        XCTAssertTrue(helperSource.contains("BOOTPD_PROFILE=/etc/bootpd.plist"))
        XCTAssertTrue(helperSource.contains("dhcpServerEnabled"))
        XCTAssertTrue(helperSource.contains("-extract dhcp_enabled json"))
        XCTAssertTrue(helperSource.contains("*'\"bridge0\"'*"))
        XCTAssertFalse(helperSource.contains("NetworkPassword"))
        XCTAssertFalse(helperSource.contains("NetworkName"))
        XCTAssertFalse(helperSource.contains("ps -axo command"))
        XCTAssertTrue(helperSource.contains("-convert json -o - \"$GUARDIAN_STATUS\""))
        XCTAssertFalse(helperSource.contains("-lint \"$GUARDIAN_STATUS\""))
        XCTAssertTrue(installerSource.contains("com.zjah.NetBarMiniNetworkGuardian"))
        let guardianPlistSource = try String(contentsOf: guardianPlist)
        XCTAssertTrue(guardianPlistSource.contains("com.zjah.NetBarMiniNetworkGuardian"))
        XCTAssertTrue(guardianPlistSource.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(helperSource.contains("SLEEP=/bin/sleep"))
        XCTAssertTrue(helperSource.contains("wait_for_management_alias"))
        XCTAssertTrue(helperSource.contains("for attempt in {1..10}"))
        XCTAssertTrue(helperSource.contains("if ($4 != \"bridge0\")"))
        XCTAssertFalse(helperSource.contains("if ($NF != \"bridge0\")"))
    }

    func testGuardianUsesDynamicStoreAndNeverRewritesDNSOrAlternativeUpstreams() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/NetBarMiniNetworkGuardian/main.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("SCDynamicStoreSetNotificationKeys"))
        XCTAssertTrue(source.contains("State:/Network/Interface/"))
        XCTAssertTrue(source.contains("system/com.apple.NetworkSharing"))
        XCTAssertTrue(source.contains("/bin/kill"))
        XCTAssertTrue(source.contains("NativeSharingProcessIdentity.pid"))
        XCTAssertTrue(source.contains("[\"kickstart\", \"system/com.apple.NetworkSharing\"]"))
        XCTAssertFalse(source.contains("\"kickstart\", \"-k\""))
        XCTAssertFalse(source.contains("\"-w\", \"net.inet.ip.forwarding"))
        XCTAssertTrue(source.contains("GuardianEvaluationCadence.duringRecoveryBackoff"))
        XCTAssertTrue(source.contains("transition(to: .recoveryBackoff, error: status.lastError)"))
        XCTAssertFalse(source.contains("-setmanual"))
        XCTAssertFalse(source.contains("-setdnsservers"))
        XCTAssertFalse(source.contains("-setnetworkserviceenabled"))
        XCTAssertTrue(source.contains("/usr/sbin/system_profiler"))
        XCTAssertTrue(source.contains("/usr/sbin/arp"))
        XCTAssertFalse(source.contains("en8"))
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
            verificationAttempts: 3,
            verificationInterval: 0,
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

    private static func bridge(
        address: String?,
        active: Bool,
        includeManagement: Bool = true
    ) -> String {
        var lines = ["bridge0: flags=8863<UP,RUNNING>"]
        if includeManagement { lines.append("\tinet 10.254.254.2 netmask 0xfffffffc") }
        if let address { lines.append("\tinet \(address) netmask 0xffffff00") }
        lines.append("\tstatus: \(active ? "active" : "inactive")")
        return lines.joined(separator: "\n")
    }

    private static let readyHelperJSON = """
    {"protocolVersion":5,"configured":true,"serviceIPv4":"192.168.2.1","gatewayIPv4":"192.168.2.1","managementIPv4":"10.254.254.1","managementPeerIPv4":"10.254.254.2","bridgeUsesDHCP":true,"sharingIntentEnabled":true,"hotspotAPConfigured":true,"upstreamDevice":"en0","upstreamActive":true,"sharingConfigured":true,"sharingProcessRunning":true,"forwardingEnabled":true,"guardianObservedAt":"2026-08-27T08:39:00Z","guardianGeneration":1,"evidenceConflict":false,"guardian":{"state":"ready","observedAt":"2026-08-27T08:39:00Z","generation":1,"lastTransition":null,"lastCarrierChange":null,"lastAction":null,"lastError":null,"carrierActive":true,"addressReady":true,"routeReady":true,"sharingRunning":true,"forwardingEnabled":true,"sharingConfigured":true,"upstreamReachable":true,"nextRetryAt":null,"managementAddressReady":true,"bridgeUsesDHCP":true,"sharingIntentEnabled":true,"hotspotAPConfigured":true}}
    """
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
    let reachableProbeTargets: Set<String>?
    let manualConfiguration: Bool
    let dnsConfigured: Bool
    let remoteHelperJSON: String?
    let defaultRouteInterface: String
    let nwiPrimaryInterface: String?
    let serviceAddress: String
    private(set) var invocations: [Invocation] = []

    init(
        bridgeOutput: String,
        router: String?,
        peerReachable: Bool = true,
        boundEgressReachable: Bool = true,
        reachableProbeTargets: Set<String>? = nil,
        manualConfiguration: Bool = false,
        dnsConfigured: Bool = true,
        remoteHelperJSON: String? = nil,
        defaultRouteInterface: String = "en0",
        nwiPrimaryInterface: String? = nil,
        serviceAddress: String = "192.168.2.2"
    ) {
        self.bridgeOutput = bridgeOutput
        self.router = router
        self.peerReachable = peerReachable
        self.boundEgressReachable = boundEgressReachable
        self.reachableProbeTargets = reachableProbeTargets
        self.manualConfiguration = manualConfiguration
        self.dnsConfigured = dnsConfigured
        self.remoteHelperJSON = remoteHelperJSON
        self.defaultRouteInterface = defaultRouteInterface
        self.nwiPrimaryInterface = nwiPrimaryInterface
        self.serviceAddress = serviceAddress
    }

    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        invocations.append(.init(executable: executable, arguments: arguments))
        if executable == "/usr/sbin/networksetup", arguments == ["-listnetworkserviceorder"] {
            return .success(Self.serviceOrder)
        }
        if executable == "/sbin/ifconfig" { return .success(bridgeOutput) }
        if executable == "/usr/sbin/networksetup", arguments.first == "-getinfo" {
            let method = manualConfiguration ? "Manual Configuration" : "DHCP Configuration"
            return .success("\(method)\nIP address: \(serviceAddress)\nSubnet mask: 255.255.255.0\nRouter: \(router ?? "none")")
        }
        if executable == "/usr/sbin/networksetup", arguments.first == "-getdnsservers" {
            return .success(dnsConfigured
                ? "192.168.2.1"
                : "There aren't any DNS Servers set on Thunderbolt Bridge.")
        }
        if executable == "/sbin/route" { return .success("interface: \(defaultRouteInterface)") }
        if executable == "/usr/sbin/scutil", arguments == ["--nwi"], let nwiPrimaryInterface {
            return .success("Network interfaces: \(nwiPrimaryInterface) en0")
        }
        if executable == "/sbin/ping" {
            if arguments.last == "10.254.254.1" { return peerReachable ? .success() : .failure("timeout") }
            return .failure("public ICMP must not be used as readiness evidence")
        }
        if executable == "/usr/bin/curl" {
            if let reachableProbeTargets, let target = arguments.last {
                guard reachableProbeTargets.contains(target) else { return .failure("timeout") }
                return .success(target.contains("generate_204") ? "204" : "200")
            }
            guard boundEgressReachable, let target = arguments.last else { return .failure("timeout") }
            return .success(target.contains("generate_204") ? "204" : "200")
        }
        if executable == "/usr/bin/ssh", let remoteHelperJSON {
            return .success(remoteHelperJSON)
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
    var addressVerificationFailuresRemaining = 0
    var pingVerificationFailuresRemaining = 0
    var localInfo = "DHCP Configuration\nIP address: 169.254.2.4\nSubnet mask: 255.255.0.0\nRouter: none"
    var localDNSOutput = "There aren't any DNS Servers set on Thunderbolt Bridge."
    private(set) var privilegedConfigurations: [(serviceName: String, configuration: NetworkServiceConfiguration)] = []
    private(set) var remoteActions: [String] = []
    private(set) var addressVerificationChecks = 0
    private(set) var pingVerificationChecks = 0

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
                pingVerificationChecks += 1
                if pingVerificationFailuresRemaining > 0 {
                    pingVerificationFailuresRemaining -= 1
                    return .failure("timeout")
                }
                return fixedLinkVerificationSucceeds ? .success() : .failure("timeout")
            }
            return .success()
        }
        if executable == "/usr/bin/ssh" {
            if arguments.last == "/usr/bin/true" {
                return remoteIdentityValid ? .success() : .failure("REMOTE HOST IDENTIFICATION HAS CHANGED")
            }
            if let action = arguments.last,
               ["status", "prepare", "migrate", "rollback", "finalize-rollback"].contains(action) {
                remoteActions.append(action)
                if action == "status" {
                    return remoteHelperInstalled
                        ? .success("{\"protocolVersion\":5}")
                        : .failure("missing")
                }
                if action == "rollback" { return remoteRollbackSucceeds ? .success("{}") : .failure("rollback failed") }
                return .success("{}")
            }
            return .success()
        }
        if executable == "/usr/sbin/networksetup", arguments.first == "-getinfo" {
            return .success(localInfo)
        }
        if executable == "/usr/sbin/networksetup", arguments.first == "-getdnsservers" {
            return .success(localDNSOutput)
        }
        if executable == "/sbin/ifconfig", arguments == ["-a"] {
            return .success("bridge0: flags=8863<UP,RUNNING>")
        }
        if executable == "/usr/sbin/netstat" { return .success("Routing tables") }
        if executable == "/sbin/ifconfig" {
            addressVerificationChecks += 1
            if addressVerificationFailuresRemaining > 0 {
                addressVerificationFailuresRemaining -= 1
                return .success("inet 169.254.2.4 netmask 0xffff0000\nstatus: active")
            }
            return fixedLinkVerificationSucceeds
                ? .success("inet 10.254.254.2 netmask 0xfffffffc\ninet 192.168.3.2 netmask 0xffffff00\nstatus: active")
                : .success("inet 169.254.2.4 netmask 0xffff0000\nstatus: active")
        }
        return .failure("unexpected command: \(executable) \(arguments)")
    }

    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult { .success() }

    func runPrivilegedEnsureManagementAlias(address: String, subnetMask: String) -> NetworkModeCommandResult {
        .success()
    }

    func runPrivilegedManagementMigration(
        serviceName: String,
        address: String,
        subnetMask: String,
        dnsServers: [String]
    ) -> NetworkModeCommandResult {
        let configuration = NetworkServiceConfiguration(
            method: .dhcp,
            ipAddress: nil,
            subnetMask: nil,
            router: nil,
            dnsServers: dnsServers
        )
        privilegedConfigurations.append((serviceName, configuration))
        localDNSOutput = dnsServers.isEmpty
            ? "There aren't any DNS Servers set on Thunderbolt Bridge."
            : dnsServers.joined(separator: "\n")
        localInfo = "DHCP Configuration\nIP address: 192.168.3.2\nSubnet mask: 255.255.255.0\nRouter: 192.168.3.1"
        return localApplySucceeds ? .success() : .failure("本机地址面迁移失败")
    }

    func runPrivilegedRemoveManagementAlias(address: String) -> NetworkModeCommandResult { .success() }

    func runPrivilegedNetworkConfiguration(
        serviceName: String,
        configuration: NetworkServiceConfiguration
    ) -> NetworkModeCommandResult {
        privilegedConfigurations.append((serviceName, configuration))
        localDNSOutput = configuration.dnsServers.isEmpty
            ? "There aren't any DNS Servers set on Thunderbolt Bridge."
            : configuration.dnsServers.joined(separator: "\n")
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
