import XCTest
import Combine
@testable import NetBar

#if !APP_STORE
final class ClashNetworkModeTests: XCTestCase {
    func testObserveConfigurationDoesNotProbeOrMutate() {
        let backend = ObservationBackend()
        let snapshot = ClashModeObserver(backend: backend).observe()
        XCTAssertTrue(snapshot.configurationMatches, snapshot.reason ?? "")
        XCTAssertEqual(snapshot.selectedNode, "Node A")
        XCTAssertEqual(backend.probeCount, 0)
    }
    func testProbeIsBoundToCurrentNetworkAndExpires() {
        let backend = ObservationBackend(); let observer = ClashModeObserver(backend: backend)
        let snapshot = observer.observe(); let date = Date()
        let probe = observer.probe(snapshot, now: date)
        XCTAssertTrue(probe.passed, probe.detail)
        XCTAssertTrue(probe.isFresh(for: snapshot, now: date))
        backend.network = "changed"
        XCTAssertFalse(probe.isFresh(for: observer.observe(), now: date))
        XCTAssertFalse(probe.isFresh(for: snapshot, now: date.addingTimeInterval(301)))
    }
    func testManifestOrAutomaticLeafChangeInvalidatesEvidence() {
        let backend = ObservationBackend(); let observer = ClashModeObserver(backend: backend)
        let snapshot = observer.observe(); let probe = observer.probe(snapshot)
        var changed = snapshot
        changed.configurationMatches = false
        XCTAssertFalse(probe.isFresh(for: changed))
        let runtime = backend.state
        let other = ClashModeRuntime(profileUID: runtime.profileUID, tunEnabled: true, systemProxyEnabled: true, runtimeRuleMode: true,
            markers: runtime.markers, selectors: runtime.selectors.merging(["Auto": "Node B"], uniquingKeysWith: { _, n in n }),
            members: runtime.members, proxyTypes: runtime.proxyTypes.merging(["Auto": "URLTest"], uniquingKeysWith: { _, n in n }),
            hijacksUDPAndTCP: true, ipv6Enabled: true)
        changed.runtime = other
        XCTAssertFalse(probe.isFresh(for: changed))
    }
    func testUnknownRuntimeNeverKeepsEvidenceValid() {
        let backend = ObservationBackend(); let observer = ClashModeObserver(backend: backend)
        let probe = observer.probe(observer.observe())
        backend.unavailable = true
        XCTAssertFalse(probe.isFresh(for: observer.observe()))
    }
    func testConcurrentNetworkChangeDuringProbeInvalidatesResult() {
        let backend = ObservationBackend(); backend.changeDuringProbe = true
        let observer = ClashModeObserver(backend: backend)
        let result = observer.probe(observer.observe())
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.detail.contains("变化"))
    }
    func testRuntimeDriftAndVPNUnknownPreventProbeSuccess() {
        let backend = ObservationBackend(); let observer = ClashModeObserver(backend: backend)
        backend.state.ipv6Enabled = false
        XCTAssertFalse(observer.observe().configurationMatches)
        XCTAssertFalse(observer.probe(observer.observe()).passed)
        backend.state.ipv6Enabled = true; backend.vpnUnknown = true
        let snapshot = observer.observe()
        XCTAssertTrue(snapshot.reason?.contains("统一保障条件未满足") == true)
        XCTAssertFalse(observer.probe(snapshot).passed)
    }
    func testFailedDNSDoesNotBecomeHTTPSOnlySuccess() {
        let backend = ObservationBackend(); backend.failDNS = true
        let observer = ClashModeObserver(backend: backend)
        let result = observer.probe(observer.observe())
        XCTAssertFalse(result.passed)
        XCTAssertEqual(backend.httpsCount, 0)
    }
    func testVersionOneIsMigrationOnly() throws {
        var manifest = try ObservationBackend().manifest()
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "configRoot": "/tmp/clash", "modes": []])
        manifest = try JSONDecoder().decode(ClashModeManifest.self, from: data)
        XCTAssertThrowsError(try manifest.entry(for: .unifiedEgress))
    }
    func testRefreshIsSingleFlightAndNeverStartsProbe() {
        let backend = ObservationBackend(); let controller = ClashNetworkModeController(backend: backend)
        let done = expectation(description: "refresh")
        let token = controller.$isRefreshing.dropFirst().filter { !$0 }.sink { _ in done.fulfill() }
        controller.refresh(); controller.detectCurrentNetwork()
        XCTAssertTrue(controller.isRefreshing); XCTAssertFalse(controller.isProbing)
        wait(for: [done], timeout: 2)
        XCTAssertNil(controller.probe); XCTAssertEqual(backend.probeCount, 0)
        withExtendedLifetime(token) {}
    }
    func testTunMembershipIgnoresOrderButNotAdditionalBypass() throws {
        let a: [String: Any] = ["route-exclude-address": ["10.0.0.0/8", "172.16.0.0/12"]]
        var b: [String: Any] = ["route-exclude-address": ["172.16.0.0/12", "10.0.0.0/8", "10.0.0.0/8"]]
        XCTAssertEqual(try ClashDNSPathEvidence.tunCaptureSHA256(a), try ClashDNSPathEvidence.tunCaptureSHA256(b))
        b["exclude-interface"] = ["en0"]
        XCTAssertNotEqual(try ClashDNSPathEvidence.tunCaptureSHA256(a), try ClashDNSPathEvidence.tunCaptureSHA256(b))
    }
    func testFreshDNSLogsRequireEveryQueryAndCorrectGroupLeaf() {
        let logs = #"{"payload":"[DNS] a.claude.ai --> TXT from https://1.1.1.1:443/dns-query"}"#
        XCTAssertEqual(ClashDNSPathEvidence.freshUpstreams(logs: logs, names: ["a.claude.ai"]), ["1.1.1.1"])
        XCTAssertNil(ClashDNSPathEvidence.freshUpstreams(logs: logs, names: ["a.claude.ai", "missing.claude.ai"]))
        let row: [String: Any] = ["metadata": ["destinationIP": "1.1.1.1", "destinationPort": "443", "specialProxy": "🌐 统一出口"], "chains": ["🌐 统一出口", "Node A"]]
        XCTAssertTrue(ClashDNSPathEvidence.confirmsChains([row], upstreams: ["1.1.1.1"], group: "🌐 统一出口", leaf: "Node A"))
        XCTAssertFalse(ClashDNSPathEvidence.confirmsChains([row], upstreams: ["1.1.1.1"], group: "🌐 统一出口", leaf: "Node B"))
    }
}

private final class ObservationBackend: ClashNetworkModeBackend {
    static let hash = String(repeating: "c", count: 64)
    static let policy = ClashTunPolicy(autoRoute: true, autoDetectInterface: true, strictRoute: false, dnsHijack: ["any:53", "tcp://any:53"], routeExcludeAddress: ["10.0.0.0/8"])
    var network = "network-one", unavailable = false, vpnUnknown = false, changeDuringProbe = false, failDNS = false
    var probeCount = 0, httpsCount = 0
    var state = ClashModeRuntime(profileUID: "unified", tunEnabled: true, systemProxyEnabled: true, runtimeRuleMode: true,
        markers: ["DOMAIN,netbar-mode-unified.invalid,🌐 统一出口"], selectors: ["🌐 统一出口": "Node A"],
        members: ["🌐 统一出口": ["Node A"]], proxyTypes: ["🌐 统一出口": "Selector", "Node A": "Vless"],
        hijacksUDPAndTCP: true, ipv6Enabled: true, rulesSHA256: hash, dnsSHA256: "dns", tunPolicy: policy, tunCaptureSHA256: "capture")
    func manifest() throws -> ClashModeManifest {
        .init(activationOwner: "clash-native", networkSettingsOwner: "clash-native", ipv6Policy: "capture-and-reject-public", schemaVersion: 2, configRoot: "/tmp/clash", modes: [
            .init(id: "company-coexistence", profileUID: "company", profileFile: "company.yaml", displayName: "公司共存", sourceSHA256: Self.hash, ruleMarker: "DOMAIN,netbar-mode-coexistence.invalid,DIRECT", targetGroup: "🧲 Claude"),
            .init(id: "unified-egress", profileUID: "unified", profileFile: "unified.yaml", displayName: "统一出口", sourceSHA256: Self.hash, ruleMarker: "DOMAIN,netbar-mode-unified.invalid,🌐 统一出口", targetGroup: "🌐 统一出口", expectedRulesSHA256: Self.hash, expectedIPv6: true, expectedDNSSHA256: "dns", expectedTunPolicy: Self.policy, expectedTunCaptureSHA256: "capture", expectedUnifiedMembersSHA256: state.membersSHA256("🌐 统一出口"))])
    }
    func runtime() throws -> ClashModeRuntime { if unavailable { throw ClashModeFailure("unavailable") }; return state }
    func networkFingerprint() throws -> String { network }
    func assertCompanyVPNDisconnected() throws { if vpnUnknown { throw ClashModeFailure("VPN unknown") } }
    func verifyDNSPath(mode: ClashNetworkMode, entry: ClashModeManifest.Entry, leaf: String) throws {
        probeCount += 1
        if failDNS { throw ClashModeFailure("no DNS evidence") }
        if changeDuringProbe { network = "changed" }
    }
    func verifySystemHTTPS() throws { httpsCount += 1 }
}
#endif
