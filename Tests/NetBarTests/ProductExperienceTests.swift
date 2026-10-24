import XCTest
@testable import NetBar

final class ProductExperienceTests: XCTestCase {
    private func snapshot() -> ClashNetworkModeSnapshot {
        let runtime = ClashModeRuntime(profileUID: "company", tunEnabled: true, systemProxyEnabled: true,
            runtimeRuleMode: true, markers: [], selectors: [:], members: [:], proxyTypes: [:],
            hijacksUDPAndTCP: true, ipv6Enabled: true)
        return .init(mode: .companyCoexistence, runtime: runtime, configurationMatches: true, networkFingerprint: "network-a")
    }
    func testPhysicalProofRemainsAvailableWhenClashWasNeverTested() {
        let p = ExperiencePresentation(proof: .activeVerified, mode: .macMiniGateway, hasPhysicalSample: true,
            physicalError: nil, clash: snapshot(), probe: nil, previousProbe: nil, probing: false)
        XCTAssertEqual(p.headline, "网络可用"); XCTAssertEqual(p.probeState, .notChecked)
        XCTAssertEqual(p.physicalPath, "雷雳 → Mac mini")
        XCTAssertTrue(p.strategy.contains("按域名分流"))
    }
    func testInitialUnknownDoesNotBecomeAnOfflineFailure() {
        let p = ExperiencePresentation(proof: .unavailable, mode: nil, hasPhysicalSample: false,
            physicalError: nil, clash: .init(), probe: nil, previousProbe: nil, probing: false)
        XCTAssertEqual(p.state, .unknown); XCTAssertEqual(p.headline, "正在读取网络")
    }
    func testObservedRouteWithoutConnectivityProofIsStillUnknown() {
        let p = ExperiencePresentation(proof: .unavailable, mode: .macMiniGateway, hasPhysicalSample: true,
            physicalError: nil, clash: snapshot(), probe: nil, previousProbe: nil, probing: false)
        XCTAssertEqual(p.state, .unknown); XCTAssertEqual(p.headline, "出口待验证")
    }
    func testProbeStatesDistinguishBlockedFailedStaleAndRunning() {
        let s = snapshot(), now = Date()
        var probe = ClashNetworkProbe(fingerprint: s.evidenceFingerprint, sampledAt: now, passed: false, detail: "条件不足", blocked: true)
        func state(_ p: ClashNetworkProbe?, _ running: Bool = false, _ date: Date = now) -> ProbeDisplayState {
            .resolve(snapshot: s, probe: p, previous: nil, running: running, now: date)
        }
        XCTAssertEqual(state(probe), .blocked)
        probe.blocked = false; XCTAssertEqual(state(probe), .failed)
        XCTAssertEqual(state(probe, false, now.addingTimeInterval(300)), .stale)
        XCTAssertEqual(state(probe, true), .running)
        XCTAssertEqual(state(nil), .notChecked)
        XCTAssertEqual(ProbeDisplayState.resolve(snapshot: s, probe: nil, previous: probe, running: false), .stale)
    }
    func testIdentityChangeImmediatelyMakesGreenResultStale() {
        let s = snapshot(), now = Date()
        let p = ClashNetworkProbe(fingerprint: s.evidenceFingerprint, sampledAt: now, passed: true, detail: "DNS/HTTPS")
        XCTAssertEqual(ProbeDisplayState.resolve(snapshot: s, probe: p, previous: nil, running: false, now: now), .passed)
        var other = s; other.networkFingerprint = "network-b"
        XCTAssertEqual(ProbeDisplayState.resolve(snapshot: other, probe: p, previous: nil, running: false, now: now), .stale)
    }
    func testVisibleConsumersCannotHideAnotherWindow() {
        var c = VisibleDataConsumers(); c.set("popover", visible: true); c.set("detail", visible: true)
        c.set("popover", visible: false); XCTAssertTrue(c.needsDetails)
        c.set("detail", visible: false); XCTAssertFalse(c.needsDetails)
        c.set("detail", visible: false); XCTAssertTrue(c.consumers.isEmpty)
    }
    func testApplicationSearchRouteAndNumericSortPreserveIdentity() {
        let a = ProcessTrafficMonitor.AppTraffic(id: "a", name: "Safari", downloadSpeed: 10, uploadSpeed: 100, cumulativeDownload: 50, cumulativeUpload: 0, proxyStatus: .unknown)
        let b = ProcessTrafficMonitor.AppTraffic(id: "b", name: "Obsidian", downloadSpeed: 80, uploadSpeed: 1, cumulativeDownload: 90, cumulativeUpload: 0, proxyStatus: .proxied)
        XCTAssertEqual(ApplicationTrafficQuery.rows([a,b], search: "SAF", route: "全部路由", sort: .total, cumulative: false).map(\.id), ["a"])
        XCTAssertEqual(ApplicationTrafficQuery.rows([a,b], search: "", route: "全部路由", sort: .upload, cumulative: false).map(\.id), ["a","b"])
        XCTAssertEqual(ApplicationTrafficQuery.rows([a,b], search: "", route: "全部路由", sort: .total, cumulative: true).map(\.id), ["b","a"])
        XCTAssertEqual(ApplicationTrafficQuery.rows([a,b], search: "", route: a.proxyStatus.label, sort: .total, cumulative: true).map(\.id), ["a"])
        XCTAssertTrue(a.routeEvidence.contains("待确认"))
    }
    private var values: ConnectionSettingsValues {
        .init(socket: "", url: "http://127.0.0.1:9090", secret: "", ipEnabled: false, ipVersion: .auto, ipMinutes: 5, hideSSID: true, apiKey: "")
    }
    func testDraftDoesNotWriteUntilSaveAndCancelReadsCurrent() {
        var stored = values, writes = 0
        let draft = SettingsDraft(read: { stored }, write: { stored = $0; writes += 1 })
        draft.values.url = "http://127.0.0.1:9999"
        XCTAssertEqual(writes, 0); XCTAssertTrue(draft.hasChanges)
        draft.discard(); XCTAssertFalse(draft.hasChanges); XCTAssertEqual(writes, 0)
        draft.values.url = "http://127.0.0.1:9999"
        XCTAssertTrue(draft.persist()); XCTAssertEqual(writes, 1); XCTAssertFalse(draft.hasChanges)
    }
    func testCredentialWriteFailureKeepsUnsavedDraftForRetry() {
        let stored = values
        let draft = SettingsDraft(read: { stored }, write: { _ in })
        draft.values.secret = "test-only"
        XCTAssertFalse(draft.persist()); XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.values.secret, "test-only"); XCTAssertTrue(draft.message?.contains("草稿已保留") == true)
    }
    func testExternalSettingsChangeBlocksOverwrite() {
        var stored = values, writes = 0
        let draft = SettingsDraft(read: { stored }, write: { _ in writes += 1 })
        draft.values.url = "http://127.0.0.1:9999"; stored.socket = "/tmp/other.sock"
        XCTAssertFalse(draft.persist()); XCTAssertEqual(writes, 0)
    }
    func testSettingsRejectURLCredentialsAndRelativeSocket() {
        var v = values; v.url = "http://user:password@localhost"; XCTAssertNotNil(v.validationError)
        v = values; v.socket = "relative.sock"; XCTAssertNotNil(v.validationError)
    }
    func testMissingQuotaDoesNotBecomeUnlimitedAndZeroTrafficIsValid() throws {
        let missing = try XCTUnwrap(ThreeXUIInboundData(from: ["up": 0, "down": 0]))
        let unlimited = try XCTUnwrap(ThreeXUIInboundData(from: ["up": 0, "down": 0, "total": 0]))
        XCTAssertFalse(missing.quotaKnown); XCTAssertTrue(unlimited.quotaKnown)
        let row = VPSTrafficMonitor.VPSTraffic(id: "test", name: "test", upload: 0, download: 0, total: 0,
            totalLimit: 0, protocol_: "", port: 0, clients: [], lastUpdated: nil, isOnline: false, error: "failure")
        XCTAssertFalse(row.hasData); XCTAssertEqual(row.formattedLimit, "额度未知")
    }
}
