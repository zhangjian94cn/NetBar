import XCTest
@testable import NetBar

final class NetworkModeControllerTests: XCTestCase {
    func testParsesServiceOrderWithSpacesUnicodeDisabledAndEmptyDevice() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) *USB 调试 服务
        (Hardware Port: USB JTAG/serial debug unit, Device: usbmodem101)
        (2) 雷雳专线
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        (3) Office Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (4) Tailscale
        (Hardware Port: io.tailscale.ipn.macsys, Device: )
        """

        let services = LiveNetworkModeSystemProvider.parseServiceOrder(output)

        XCTAssertEqual(services, [
            NetworkServiceEntry(
                name: "USB 调试 服务",
                hardwarePort: "USB JTAG/serial debug unit",
                device: "usbmodem101",
                isDisabled: true
            ),
            NetworkServiceEntry(
                name: "雷雳专线",
                hardwarePort: "Thunderbolt Bridge",
                device: "bridge0",
                isDisabled: false
            ),
            NetworkServiceEntry(
                name: "Office Wi-Fi",
                hardwarePort: "Wi-Fi",
                device: "en0",
                isDisabled: false
            ),
            NetworkServiceEntry(
                name: "Tailscale",
                hardwarePort: "io.tailscale.ipn.macsys",
                device: "",
                isDisabled: false
            )
        ])
    }

    func testInterfaceAndRouteParsersIgnoreIPv6AndWhitespace() {
        let ifconfig = """
        bridge0: flags=8863<UP,RUNNING>
            inet6 fe80::1%bridge0 prefixlen 64
            inet 192.168.2.2 netmask 0xffffff00
            status: active
        """
        let route = """
           route to: default
          interface: bridge0
        """

        XCTAssertTrue(LiveNetworkModeSystemProvider.parseInterfaceActive(ifconfig))
        XCTAssertEqual(LiveNetworkModeSystemProvider.parseInterfaceIPv4(ifconfig), "192.168.2.2")
        XCTAssertEqual(LiveNetworkModeSystemProvider.parseInterfaceIPv4s(ifconfig), ["192.168.2.2"])
        XCTAssertEqual(LiveNetworkModeSystemProvider.parseRouteInterface(route), "bridge0")
    }

    func testReorderingSwapsOnlyWiFiAndThunderbolt() {
        let snapshot = makeSnapshot(
            names: ["USB Debug", "Thunderbolt Bridge", "Wi-Fi", "Tailscale"],
            defaultInterface: "bridge0",
            linkState: .connected
        )

        XCTAssertEqual(snapshot.reorderedServices(for: .localWiFi), [
            "USB Debug", "Wi-Fi", "Thunderbolt Bridge", "Tailscale"
        ])
        XCTAssertEqual(snapshot.serviceNames, [
            "USB Debug", "Thunderbolt Bridge", "Wi-Fi", "Tailscale"
        ])
    }

    func testEffectiveModeUsesPhysicalDefaultInsteadOfTunnelRoute() {
        let snapshot = makeSnapshot(
            names: ["Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
            defaultInterface: "en0",
            linkState: .connected
        )

        XCTAssertEqual(snapshot.intendedMode, .localWiFi)
        XCTAssertEqual(snapshot.effectiveMode, .localWiFi)
        XCTAssertTrue(snapshot.isConsistent)
    }

    func testSwitchToWiFiPreservesAllServicesAndVerifiesRoute() {
        let initial = makeSnapshot(
            names: ["USB Debug", "Thunderbolt Bridge", "Wi-Fi", "Tailscale"],
            defaultInterface: "bridge0",
            linkState: .connected
        )
        let verified = makeSnapshot(
            names: ["USB Debug", "Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
            defaultInterface: "en0",
            linkState: .connected
        )
        let provider = MockNetworkModeProvider(
            snapshots: [initial, verified],
            setResults: [.success]
        )
        let engine = makeEngine(provider: provider)

        let outcome = engine.switchMode(to: .localWiFi)

        XCTAssertEqual(outcome.kind, .success)
        XCTAssertEqual(provider.orders, [["USB Debug", "Wi-Fi", "Thunderbolt Bridge", "Tailscale"]])
        XCTAssertEqual(outcome.snapshot, verified)
    }

    func testAlreadyVerifiedModeDoesNotWriteSystemConfiguration() {
        let initial = makeSnapshot(
            names: ["Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
            defaultInterface: "en0",
            linkState: .connected
        )
        let provider = MockNetworkModeProvider(snapshots: [initial], setResults: [])

        let outcome = makeEngine(provider: provider).switchMode(to: .localWiFi)

        XCTAssertEqual(outcome.kind, .unchanged)
        XCTAssertTrue(provider.orders.isEmpty)
    }

    func testGatewayPreflightRejectsEveryUnhealthyLinkState() {
        let rejectedStates: [ThunderboltLinkState] = [
            .disconnected, .addressNotProvisioned, .miniUnreachable, .unavailable
        ]

        for linkState in rejectedStates {
            let initial = makeSnapshot(
                names: ["Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
                defaultInterface: "en0",
                linkState: linkState
            )
            let provider = MockNetworkModeProvider(snapshots: [initial], setResults: [])

            let outcome = makeEngine(provider: provider).switchMode(to: .macMiniGateway)

            XCTAssertEqual(outcome.kind, .failed, "state: \(linkState)")
            XCTAssertEqual(outcome.message, linkState.displayName)
            XCTAssertTrue(provider.orders.isEmpty)
        }
    }

    func testGatewayPreflightRejectsUnavailableBoundEgress() {
        let initial = makeSnapshot(
            names: ["Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
            defaultInterface: "en0",
            linkState: .connected,
            gatewayState: .boundEgressUnavailable
        )
        let provider = MockNetworkModeProvider(snapshots: [initial], setResults: [])

        let outcome = makeEngine(provider: provider).switchMode(to: .macMiniGateway)

        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(outcome.message, "Mac mini 出口探测失败")
        XCTAssertTrue(provider.orders.isEmpty)
    }

    func testLinkLocalAndUnexpectedAddressesAreNotProvisioned() {
        XCTAssertTrue(MacMiniLinkProfile.isLinkLocalIPv4("169.254.12.34"))
        XCTAssertFalse(MacMiniLinkProfile.isLinkLocalIPv4("192.168.2.2"))
        XCTAssertNotEqual("192.168.3.2", MacMiniLinkProfile.defaults.localAddress)
    }

    func testMissingRequiredServiceFailsClosed() {
        let initial = makeSnapshot(
            names: ["Wi-Fi", "Tailscale"],
            defaultInterface: "en0",
            linkState: .unavailable,
            includeThunderbolt: false
        )
        let provider = MockNetworkModeProvider(snapshots: [initial], setResults: [])

        let outcome = makeEngine(provider: provider).switchMode(to: .localWiFi)

        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(outcome.message, "未同时发现 Wi-Fi 与雷雳网桥服务")
        XCTAssertTrue(provider.orders.isEmpty)
    }

    func testCommandFailureDoesNotAttemptRollback() {
        let initial = makeSnapshot(
            names: ["Thunderbolt Bridge", "Wi-Fi", "Tailscale"],
            defaultInterface: "bridge0",
            linkState: .connected
        )
        let provider = MockNetworkModeProvider(
            snapshots: [initial, initial],
            setResults: [.failure("permission denied")]
        )

        let outcome = makeEngine(provider: provider).switchMode(to: .localWiFi)

        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(provider.orders.count, 1)
        XCTAssertEqual(outcome.message, "permission denied")
    }

    func testVerificationFailureRollsBackOriginalOrder() {
        let initial = makeSnapshot(
            names: ["Thunderbolt Bridge", "Wi-Fi", "Tailscale"],
            defaultInterface: "bridge0",
            linkState: .connected
        )
        let notConverged = makeSnapshot(
            names: ["Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
            defaultInterface: "bridge0",
            linkState: .connected
        )
        let restored = initial
        let provider = MockNetworkModeProvider(
            snapshots: [initial, notConverged, notConverged, restored],
            setResults: [.success, .success]
        )

        let outcome = makeEngine(provider: provider).switchMode(to: .localWiFi)

        XCTAssertEqual(outcome.kind, .rolledBack)
        XCTAssertEqual(provider.orders, [
            ["Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
            ["Thunderbolt Bridge", "Wi-Fi", "Tailscale"]
        ])
        XCTAssertEqual(outcome.snapshot, restored)
    }

    func testRollbackFailureRequiresManualRecovery() {
        let initial = makeSnapshot(
            names: ["Thunderbolt Bridge", "Wi-Fi", "Tailscale"],
            defaultInterface: "bridge0",
            linkState: .connected
        )
        let notConverged = makeSnapshot(
            names: ["Wi-Fi", "Thunderbolt Bridge", "Tailscale"],
            defaultInterface: "bridge0",
            linkState: .connected
        )
        let provider = MockNetworkModeProvider(
            snapshots: [initial, notConverged, notConverged, notConverged],
            setResults: [.success, .failure("rollback denied")]
        )

        let outcome = makeEngine(provider: provider).switchMode(to: .localWiFi)

        XCTAssertEqual(outcome.kind, .recoveryRequired)
        XCTAssertEqual(provider.orders.count, 2)
    }

    func testAuthorizationFailureUsesPrivilegedRunnerWithoutChangingArguments() {
        let runner = MockNetworkModeCommandRunner(
            directResults: [.failure("You must be root to run this command.")],
            privilegedResult: .success
        )
        let provider = LiveNetworkModeSystemProvider(commandRunner: runner)
        let order = ["USB 调试", "Office Wi-Fi", "Thunderbolt Bridge", "Tailscale"]

        let result = provider.setServiceOrder(order)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.privilegedOrders, [order])
        XCTAssertEqual(runner.directInvocations.first?.arguments, ["-ordernetworkservices"] + order)
    }

    func testNonAuthorizationFailureDoesNotPromptForElevation() {
        let runner = MockNetworkModeCommandRunner(
            directResults: [.failure("invalid service name")],
            privilegedResult: .success
        )
        let provider = LiveNetworkModeSystemProvider(commandRunner: runner)

        let result = provider.setServiceOrder(["Wi-Fi", "Thunderbolt Bridge"])

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(runner.privilegedOrders.isEmpty)
    }

    private func makeEngine(provider: NetworkModeSystemProviding) -> NetworkModeSwitchEngine {
        NetworkModeSwitchEngine(
            provider: provider,
            verificationAttempts: 2,
            verificationInterval: 0,
            sleeper: { _ in }
        )
    }

    private func makeSnapshot(
        names: [String],
        defaultInterface: String,
        linkState: ThunderboltLinkState,
        gatewayState: MacMiniGatewayState = .ready,
        includeThunderbolt: Bool = true
    ) -> NetworkModeSnapshot {
        let services = names.map { name -> NetworkServiceEntry in
            if name == "Wi-Fi" || name == "Office Wi-Fi" {
                return NetworkServiceEntry(name: name, hardwarePort: "Wi-Fi", device: "en0", isDisabled: false)
            }
            if name == "Thunderbolt Bridge" && includeThunderbolt {
                return NetworkServiceEntry(name: name, hardwarePort: "Thunderbolt Bridge", device: "bridge0", isDisabled: false)
            }
            return NetworkServiceEntry(name: name, hardwarePort: name, device: "", isDisabled: false)
        }
        let wifi = services.first { LiveNetworkModeSystemProvider.isWiFiHardwarePort($0.hardwarePort) }
        let thunderbolt = services.first { $0.device == "bridge0" }

        return NetworkModeSnapshot(
            services: services,
            wifiServiceName: wifi?.name,
            wifiDevice: wifi?.device,
            thunderboltServiceName: thunderbolt?.name,
            thunderboltDevice: thunderbolt?.device,
            bridgeIPv4: linkState == .addressNotProvisioned || linkState == .disconnected || linkState == .unavailable ? nil : "192.168.2.2",
            miniGateway: "192.168.2.1",
            physicalDefaultInterface: defaultInterface,
            linkState: linkState,
            gatewayState: gatewayState
        )
    }
}

private final class MockNetworkModeProvider: NetworkModeSystemProviding {
    private var snapshots: [NetworkModeSnapshot]
    private var setResults: [NetworkModeCommandResult]
    private(set) var orders: [[String]] = []

    init(snapshots: [NetworkModeSnapshot], setResults: [NetworkModeCommandResult]) {
        self.snapshots = snapshots
        self.setResults = setResults
    }

    func readSnapshot() throws -> NetworkModeSnapshot {
        guard !snapshots.isEmpty else {
            throw NetworkModeSystemError.commandFailed("no mock snapshot")
        }
        if snapshots.count == 1 {
            return snapshots[0]
        }
        return snapshots.removeFirst()
    }

    func setServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        orders.append(serviceNames)
        guard !setResults.isEmpty else {
            return .failure("no mock result")
        }
        return setResults.removeFirst()
    }
}

private final class MockNetworkModeCommandRunner: NetworkModeCommandRunning {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    var directResults: [NetworkModeCommandResult]
    let privilegedResult: NetworkModeCommandResult
    private(set) var directInvocations: [Invocation] = []
    private(set) var privilegedOrders: [[String]] = []

    init(directResults: [NetworkModeCommandResult], privilegedResult: NetworkModeCommandResult) {
        self.directResults = directResults
        self.privilegedResult = privilegedResult
    }

    func run(executable: String, arguments: [String]) -> NetworkModeCommandResult {
        directInvocations.append(Invocation(executable: executable, arguments: arguments))
        guard !directResults.isEmpty else {
            return .failure("no mock result")
        }
        return directResults.removeFirst()
    }

    func runPrivilegedNetworkServiceOrder(_ serviceNames: [String]) -> NetworkModeCommandResult {
        privilegedOrders.append(serviceNames)
        return privilegedResult
    }
}

private extension NetworkModeCommandResult {
    static var success: NetworkModeCommandResult {
        NetworkModeCommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    static func failure(_ message: String) -> NetworkModeCommandResult {
        NetworkModeCommandResult(exitCode: 1, standardOutput: "", standardError: message)
    }
}
