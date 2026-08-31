import Foundation
import XCTest
@testable import NetBar

final class CompanyVPNDiagnosticMonitorTests: XCTestCase {
    func testReadsOwnerArtifactsWithoutOwningVPNConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-company-vpn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = root.appendingPathComponent(
            "zhangjian-skills/dual-vpn-config/oavpn-endpoint-diagnostic.json"
        )
        let baseline = root.appendingPathComponent(
            "zhangjian-skills/work-cmcc-automation/artifacts/latest-network-state.json"
        )
        try FileManager.default.createDirectory(
            at: endpoint.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: baseline.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "status": "healthy",
          "verified_endpoint_ips": ["183.207.73.66"],
          "observed_at_utc": "2026-08-30T06:01:29Z",
          "recommendation": "read-only recommendation"
        }
        """.utf8).write(to: endpoint)
        try Data("""
        {
          "persistent_source_state": "healthy",
          "clash_state": "running_restored",
          "proxy_state": "enabled"
        }
        """.utf8).write(to: baseline)

        let monitor = CompanyVPNDiagnosticMonitor(environment: ["XDG_STATE_HOME": root.path])
        let snapshot = monitor.collectSnapshot()

        XCTAssertEqual(snapshot.portalStatus, "入口已验证")
        XCTAssertEqual(snapshot.portalEndpoint, "183.207.73.66")
        XCTAssertEqual(snapshot.baselineStatus, "共存基线正常")
        XCTAssertEqual(snapshot.recommendation, "read-only recommendation")
        XCTAssertNotNil(snapshot.observedAt)
    }

    func testSourceDoesNotContainVPNOrClashMutationCommands() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NetBar/Monitors/CompanyVPNDiagnosticMonitor.swift"))

        XCTAssertFalse(source.contains("networksetup -set"))
        XCTAssertFalse(source.contains("DELETE /connections"))
        XCTAssertFalse(source.contains("enable_tun_mode"))
        XCTAssertFalse(source.contains("ssh"))
        XCTAssertTrue(source.contains("diagnose-oavpn-endpoint"))
    }

    func testReadsOverlayTransitionArtifactAndOffersOnlyExplicitOwnerRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-company-overlay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let overlay = root.appendingPathComponent(
            "zhangjian-skills/dual-vpn-config/overlay-transition-diagnostic.json"
        )
        try FileManager.default.createDirectory(
            at: overlay.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "schema_version": "1.0",
          "observed_at_utc": "2026-08-31T06:00:00Z",
          "classification": {
            "status": "degraded",
            "mode": "direct",
            "reason": "staleFakeIPWithoutTunRoute",
            "recovery_available": true,
            "should_change_underlay": false
          },
          "secret_redaction": true
        }
        """.utf8).write(to: overlay)

        let monitor = CompanyVPNDiagnosticMonitor(environment: ["XDG_STATE_HOME": root.path])
        let snapshot = monitor.collectSnapshot()

        XCTAssertEqual(snapshot.overlayMode, "直连兜底")
        XCTAssertEqual(snapshot.overlayReason, "Fake-IP 未随 TUN 关闭而收敛")
        XCTAssertTrue(snapshot.recoveryAvailable)
        XCTAssertNotEqual(snapshot.health, .ready)
    }

    func testRecoveryUsesFixedOwnerCommandWithoutShellOrAutomaticInvocation() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NetBar/Monitors/CompanyVPNDiagnosticMonitor.swift"))

        XCTAssertTrue(source.contains("recover-coexistence"))
        XCTAssertFalse(source.contains("/bin/sh"))
        XCTAssertFalse(source.contains("-c\""))
        XCTAssertFalse(source.contains("Timer.scheduledTimer") && source.contains("recoverCoexistence()"))
        XCTAssertTrue(source.contains("withTimeInterval: 10"))
        XCTAssertTrue(source.contains("inspectExternalOverlayTransition()"))
    }
}
