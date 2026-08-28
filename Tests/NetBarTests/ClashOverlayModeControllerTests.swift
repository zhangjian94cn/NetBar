import Foundation
import XCTest
@testable import NetBar

#if !APP_STORE
final class ClashOverlayModeControllerTests: XCTestCase {
    func testPreferenceStoreChangesOnlyUniqueTopLevelScalarAndCanRollback() throws {
        let fixture = try TemporaryVergeFixture(
            """
            language: zh
            enable_tun_mode: false
            nested:
              enable_tun_mode: ignored
            """
        )
        let store = LiveVergeTunPreferenceStore(
            configURL: fixture.configURL,
            transactionRoot: fixture.transactionRoot
        )

        XCTAssertFalse(try store.read())
        let transaction = try store.replace(with: true)
        XCTAssertTrue(try store.read())
        let changed = try String(contentsOf: fixture.configURL)
        XCTAssertTrue(changed.contains("enable_tun_mode: true"))
        XCTAssertTrue(changed.contains("  enable_tun_mode: ignored"))

        try store.rollback(transaction)
        XCTAssertFalse(try store.read())
        XCTAssertEqual(try String(contentsOf: fixture.configURL), fixture.original)
    }

    func testPreferenceStoreRejectsDuplicateTopLevelScalar() throws {
        let fixture = try TemporaryVergeFixture(
            """
            enable_tun_mode: false
            enable_tun_mode: true
            """
        )
        let store = LiveVergeTunPreferenceStore(
            configURL: fixture.configURL,
            transactionRoot: fixture.transactionRoot
        )

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? VergeTunPreferenceError, .ambiguous)
        }
    }

    func testPreferenceStoreDoesNotOverwriteExternalChangeDuringRollback() throws {
        let fixture = try TemporaryVergeFixture("enable_tun_mode: false\n")
        let store = LiveVergeTunPreferenceStore(
            configURL: fixture.configURL,
            transactionRoot: fixture.transactionRoot
        )
        let transaction = try store.replace(with: true)
        try Data("enable_tun_mode: true\nexternal: changed\n".utf8)
            .write(to: fixture.configURL, options: .atomic)

        XCTAssertThrowsError(try store.rollback(transaction)) { error in
            XCTAssertEqual(error as? VergeTunPreferenceError, .changedDuringTransaction)
        }
    }

    func testTunFullTransactionPersistsRuntimeVerifiesAndCommits() {
        let runtime = OverlayRuntimeMock(configuration: Self.configuration(tun: false, baseline: true))
        let store = OverlayPreferenceStoreMock(value: false)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: true)
        )

        controller.switchMode(to: .tunFull)

        XCTAssertTrue(waitUntil { !controller.isSwitching && controller.snapshot.mode == .tunFull })
        XCTAssertEqual(controller.snapshot.health, .ready)
        XCTAssertEqual(runtime.setValues, [true])
        XCTAssertEqual(runtime.closeCount, 1)
        XCTAssertEqual(store.commitCount, 1)
        XCTAssertEqual(store.rollbackCount, 0)
    }

    func testTunFullRefusesConfigurationDriftBeforeAnyWrite() {
        let runtime = OverlayRuntimeMock(configuration: Self.configuration(tun: false, baseline: false))
        let store = OverlayPreferenceStoreMock(value: false)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: true)
        )

        controller.switchMode(to: .tunFull)

        XCTAssertTrue(waitUntil { !controller.isSwitching })
        XCTAssertEqual(controller.snapshot.health, .configurationDrift)
        XCTAssertTrue(runtime.setValues.isEmpty)
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testRuntimeFailureRollsBackPersistentPreference() {
        let runtime = OverlayRuntimeMock(
            configuration: Self.configuration(tun: false, baseline: true),
            acceptsRuntimeWrite: false
        )
        let store = OverlayPreferenceStoreMock(value: false)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: true)
        )

        controller.switchMode(to: .tunFull)

        XCTAssertTrue(waitUntil { !controller.isSwitching })
        XCTAssertEqual(controller.snapshot.health, .degraded)
        XCTAssertEqual(store.rollbackCount, 1)
        XCTAssertFalse(store.value)
        XCTAssertEqual(runtime.setValues, [true])
    }

    func testDataPlaneFailureRestoresRuntimeAndPersistentPreference() {
        let runtime = OverlayRuntimeMock(
            configuration: Self.configuration(tun: false, baseline: true),
            probeReady: false
        )
        let store = OverlayPreferenceStoreMock(value: false)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: true)
        )

        controller.switchMode(to: .tunFull)

        XCTAssertTrue(waitUntil { !controller.isSwitching })
        XCTAssertEqual(runtime.setValues, [true, false])
        XCTAssertEqual(runtime.closeCount, 2)
        XCTAssertEqual(store.rollbackCount, 1)
        XCTAssertFalse(store.value)
    }

    func testSystemProxyModeOnlyDisablesTunAndKeepsProxyRequired() {
        let runtime = OverlayRuntimeMock(configuration: Self.configuration(tun: true, baseline: true))
        let store = OverlayPreferenceStoreMock(value: true)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: true)
        )

        controller.switchMode(to: .systemProxy)

        XCTAssertTrue(waitUntil { !controller.isSwitching && controller.snapshot.mode == .systemProxy })
        XCTAssertEqual(controller.snapshot.health, .ready)
        XCTAssertEqual(runtime.setValues, [false])
        XCTAssertTrue(controller.snapshot.systemProxyEnabled)
    }

    func testSelectingAlreadyActiveModeDoesNotRewriteOrCloseConnections() {
        let runtime = OverlayRuntimeMock(configuration: Self.configuration(tun: false, baseline: true))
        let store = OverlayPreferenceStoreMock(value: false)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: true)
        )

        controller.switchMode(to: .systemProxy)

        XCTAssertTrue(waitUntil { !controller.isSwitching && controller.snapshot.mode == .systemProxy })
        XCTAssertTrue(runtime.setValues.isEmpty)
        XCTAssertEqual(runtime.closeCount, 0)
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testSystemHTTPSFailureIsReportedAsDataPlaneDegradedWithoutModeWrite() {
        let runtime = OverlayRuntimeMock(configuration: Self.configuration(tun: false, baseline: true))
        let store = OverlayPreferenceStoreMock(value: false)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: false)
        )

        controller.switchMode(to: .systemProxy)

        XCTAssertTrue(waitUntil { !controller.isSwitching })
        XCTAssertEqual(controller.snapshot.health, .degraded)
        XCTAssertFalse(controller.snapshot.dataPlaneReady)
        XCTAssertTrue(runtime.setValues.isEmpty)
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testCommitConflictDoesNotClaimThatExternalPersistentChangeWasRestored() {
        let runtime = OverlayRuntimeMock(configuration: Self.configuration(tun: false, baseline: true))
        let store = OverlayPreferenceStoreMock(value: false, commitFails: true, rollbackFails: true)
        let controller = ClashOverlayModeController(
            runtime: runtime,
            preferenceStore: store,
            proxyInspector: OverlayProxyInspector(enabled: true),
            systemHTTPSProbe: OverlaySystemHTTPSProbe(ready: true)
        )

        controller.switchMode(to: .tunFull)

        XCTAssertTrue(waitUntil { !controller.isSwitching })
        XCTAssertEqual(controller.snapshot.health, .degraded)
        XCTAssertTrue(controller.snapshot.reason?.contains("无法确认完整恢复") == true)
        XCTAssertEqual(runtime.setValues, [true, false])
    }

    private static func configuration(tun: Bool, baseline: Bool) -> MihomoClient.RuntimeConfiguration {
        let exclusions: Set<String> = baseline ? [
            "10.0.0.0/8", "100.64.0.0/10", "172.16.0.0/12", "192.168.0.0/16",
            "192.200.0.0/24", "199.165.136.0/24", "119.45.14.85/32", "124.222.119.248/32"
        ] : []
        return .init(mixedPort: 7897, tunEnabled: tun, ipv6Enabled: !baseline, routeExclusions: exclusions)
    }

    private func waitUntil(timeout: TimeInterval = 2, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }
}

private final class TemporaryVergeFixture {
    let root: URL
    let configURL: URL
    let transactionRoot: URL
    let original: String

    init(_ original: String) throws {
        self.original = original
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-overlay-tests-\(UUID().uuidString)", isDirectory: true)
        configURL = root.appendingPathComponent("verge.yaml")
        transactionRoot = root.appendingPathComponent("transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(original.utf8).write(to: configURL)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class OverlayRuntimeMock: ClashRuntimeControlling {
    private var current: MihomoClient.RuntimeConfiguration
    private let acceptsRuntimeWrite: Bool
    private let probeReady: Bool
    private(set) var setValues: [Bool] = []
    private(set) var closeCount = 0

    init(
        configuration: MihomoClient.RuntimeConfiguration,
        acceptsRuntimeWrite: Bool = true,
        probeReady: Bool = true
    ) {
        current = configuration
        self.acceptsRuntimeWrite = acceptsRuntimeWrite
        self.probeReady = probeReady
    }

    func configuration() -> MihomoClient.RuntimeConfiguration? { current }

    func setTunEnabled(_ enabled: Bool) -> Bool {
        setValues.append(enabled)
        guard acceptsRuntimeWrite else { return false }
        current = .init(
            mixedPort: current.mixedPort,
            tunEnabled: enabled,
            ipv6Enabled: current.ipv6Enabled,
            routeExclusions: current.routeExclusions
        )
        return true
    }

    func closeAllConnections() -> Bool {
        closeCount += 1
        return true
    }

    func probeHTTPS() -> Bool { probeReady }
}

private final class OverlayPreferenceStoreMock: VergeTunPreferenceStoring {
    var value: Bool
    private var original = false
    private let commitFails: Bool
    private let rollbackFails: Bool
    private(set) var replaceCount = 0
    private(set) var rollbackCount = 0
    private(set) var commitCount = 0

    init(value: Bool, commitFails: Bool = false, rollbackFails: Bool = false) {
        self.value = value
        self.commitFails = commitFails
        self.rollbackFails = rollbackFails
    }

    func read() throws -> Bool { value }

    func replace(with enabled: Bool) throws -> VergeTunPreferenceTransaction {
        replaceCount += 1
        original = value
        value = enabled
        return .init(
            id: UUID().uuidString,
            originalData: Data(),
            originalDigest: "original",
            appliedDigest: "applied",
            originalPermissions: 0o600,
            backupURL: URL(fileURLWithPath: "/tmp/mock")
        )
    }

    func rollback(_: VergeTunPreferenceTransaction) throws {
        rollbackCount += 1
        if rollbackFails { throw VergeTunPreferenceError.changedDuringTransaction }
        value = original
    }

    func commit(_: VergeTunPreferenceTransaction) throws {
        commitCount += 1
        if commitFails { throw VergeTunPreferenceError.changedDuringTransaction }
    }
}

private struct OverlayProxyInspector: SystemProxyInspecting {
    let enabled: Bool
    func isEnabled(expectedPort _: Int) -> Bool { enabled }
}

private struct OverlaySystemHTTPSProbe: SystemHTTPSProbing {
    let ready: Bool
    func probeHTTPS() -> Bool { ready }
}
#endif
