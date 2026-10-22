import XCTest
import Combine
@testable import NetBar

#if !APP_STORE
final class ClashNetworkModeTests: XCTestCase {
    func testRefreshPublishesBusyStateAndPreventsAnOverlappingSwitch() {
        let backend = ModeBackend()
        let controller = ClashNetworkModeController(backend: backend)
        let finished = expectation(description: "readback finished")
        let token = controller.$isRefreshing.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        controller.refresh()
        XCTAssertTrue(controller.isRefreshing)
        controller.switchMode(to: .companyCoexistence)
        XCTAssertFalse(controller.isSwitching)
        wait(for: [finished], timeout: 2)
        withExtendedLifetime(token) {}
        XCTAssertFalse(backend.events.contains("dns-prepare"))
    }

    func testMihomoEmptyConnectionsAreValidButMissingAndMalformedAreNot() throws {
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"connections":null}"#.utf8)) as? [String: Any])
        XCTAssertEqual(ClashDNSPathEvidence.connections(in: payload)?.count, 0)
        XCTAssertEqual(ClashDNSPathEvidence.connections(in: ["connections": [["id": "example"]]])?.count, 1)
        XCTAssertNil(ClashDNSPathEvidence.connections(in: [:]))
        XCTAssertNil(ClashDNSPathEvidence.connections(in: ["connections": "invalid"]))
        XCTAssertNil(ClashDNSPathEvidence.connections(in: ["connections": [42]]))
    }

    func testNativeSwitchMatchesChromiumCheckboxBeyondPresentationWrappers() {
        typealias Element = ClashNativeControlMatching.Element
        let elements = [Element(title: "系统代理", role: "AXHeading")] +
            (0..<12).map { _ in Element(title: "", role: "AXGroup") } +
            [Element(title: "", role: "AXCheckBox"), Element(title: "IPv6", role: "AXHeading"), Element(title: "", role: "AXSwitch")]
        XCTAssertEqual(ClashNativeControlMatching.index(after: "系统代理", role: "AXSwitch", in: elements), 13)
        let missing = [Element(title: "系统代理", role: "AXHeading"), Element(title: "IPv6", role: "AXHeading"), Element(title: "", role: "AXCheckBox")]
        XCTAssertNil(ClashNativeControlMatching.index(after: "系统代理", role: "AXSwitch", in: missing))
        let nextStaticRow = [Element(title: "系统代理", role: "AXHeading"), Element(title: "开机自启", role: "AXStaticText"), Element(title: "", role: "AXCheckBox")]
        XCTAssertNil(ClashNativeControlMatching.index(after: "系统代理", role: "AXSwitch", in: nextStaticRow))
        XCTAssertNil(ClashNativeControlMatching.index(after: "不存在的字段", role: "AXSwitch", in: elements))
    }

    func testTunStartDoesNotLookLikeAConcurrentPolicyEdit() throws {
        func data(_ values: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ClashDNSPathEvidence.runtimeTunConfiguration(values), options: [.sortedKeys])
        }
        let before: [String: Any] = ["enable": false, "device": "", "dns-hijack": ["any:53", "tcp://any:53"], "auto-route": true]
        var started = before; started["enable"] = true; started["device"] = "utun1024"; started["inet6-address"] = ["fd00::1/126"]
        XCTAssertEqual(try data(before), try data(started))
        started["exclude-interface"] = ["en0"]
        XCTAssertNotEqual(try data(before), try data(started))
    }

    func testRuleConfigurationIgnoresTrafficCountersButTracksDisabledRules() throws {
        func data(_ count: Int, disabled: Bool = false) throws -> Data {
            let rules: [[String: Any]] = [["type": "DomainSuffix", "payload": "claude.ai", "proxy": "🧲 Claude", "size": -1,
                                          "extra": ["disabled": disabled, "hitCount": count, "missCount": count, "hitAt": "time-\(count)"]]]
            return try JSONSerialization.data(withJSONObject: ClashDNSPathEvidence.ruleConfiguration(rules), options: [.sortedKeys])
        }
        XCTAssertEqual(try data(1), try data(42))
        XCTAssertNotEqual(try data(1), try data(1, disabled: true))
        let backend = ModeBackend(); backend.activatedProblem = "disabled-rule"
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(backend.events.contains("dns-acquire"))
    }

    func testNativeRegistryAcceptsUnnamedEnhancementsWithoutWeakeningProfileIdentity() throws {
        let data = Data(#"{"current":"original","names":{"original":"Main","script":null,"merge":null,"company":"NetBar · 公司共存"}}"#.utf8)
        let registry = try JSONDecoder().decode(ClashNativeProfileRegistry.self, from: data)
        XCTAssertEqual(registry.current, "original")
        XCTAssertEqual(registry.names, ["original": "Main", "company": "NetBar · 公司共存"])
        XCTAssertThrowsError(try JSONDecoder().decode(ClashNativeProfileRegistry.self, from: Data(#"{"current":null,"names":{}}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ClashNativeProfileRegistry.self, from: Data(#"{"current":"original","names":{"original":42}}"#.utf8)))
    }

    func testReopenReadsWithoutReacquiringDNS() {
        let backend = ModeBackend(); backend.state = ModeBackend.runtime(uid: "unified", tun: true, proxy: true)
        let result = ClashModeTransactionEngine(backend: backend).observe()
        XCTAssertEqual(result.mode, .unifiedEgress)
        XCTAssertEqual(result.headline, "统一配置仍运行，DNS 未接管")
        XCTAssertFalse(result.verified)
        XCTAssertEqual(backend.events, ["runtime", "manifest", "dns-status"])
    }

    func testUnifiedVerifiesHijackBeforeDNSAndPreservesManualLeaf() {
        let backend = ModeBackend()
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertTrue(result.verified, result.reason ?? "")
        XCTAssertEqual(backend.state.profileUID, "unified")
        XCTAssertTrue(backend.state.tunEnabled)
        XCTAssertTrue(backend.state.systemProxyEnabled)
        XCTAssertEqual(backend.state.leaf(for: "🌐 统一出口"), "Node A")
        XCTAssertLessThan(backend.events.firstIndex(of: "verify-dns")!, backend.events.firstIndex(of: "dns-acquire")!)
        XCTAssertEqual(backend.events.filter { $0 == "verify-dns" }.count, 2)
        XCTAssertTrue(backend.lease.ownedByThisProcess)
        XCTAssertLessThan(backend.events.firstIndex(of: "dns-prepare")!, backend.events.firstIndex(of: "activate:unified")!)
    }

    func testOldHelperCannotStartNativeMutation() {
        let backend = ModeBackend()
        backend.lease = .init(protocolVersion: 6, dnsLeaseState: "inactive", dnsLeaseOwnerPID: nil, dnsLeaseServices: 0, reason: nil)
        XCTAssertFalse(ClashModeTransactionEngine(backend: backend).apply(.companyCoexistence).verified)
        XCTAssertFalse(backend.events.contains("dns-prepare"))
        XCTAssertFalse(backend.events.contains(where: { $0.hasPrefix("activate:") }))
    }

    func testCompanyGateFailureDoesNotMutate() {
        let backend = ModeBackend(); backend.companyBlocked = true
        let original = backend.state
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(backend.state, original)
        XCTAssertFalse(backend.events.contains(where: { $0.hasPrefix("activate:") || $0 == "dns-acquire" || $0 == "switches" }))
    }

    func testOrdinaryFailureRestoresOriginalThirdPartyProfileAndSwitches() {
        let backend = ModeBackend(); backend.failSystemHTTPS = true
        let original = backend.state
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.manualPending, result.reason ?? "")
        XCTAssertEqual(backend.state.controlFingerprint, original.controlFingerprint)
        XCTAssertEqual(backend.lease.dnsLeaseState, "inactive")
        XCTAssertTrue(backend.events.contains("restore-profile:original"))
        XCTAssertLessThan(backend.events.lastIndex(of: "switches")!, backend.events.lastIndex(of: "dns-release")!)
    }

    func testExternalConcurrentChangeIsNeverOverwritten() {
        let backend = ModeBackend(); backend.externalChangeOnVerify = true
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.manualPending)
        XCTAssertEqual(backend.state.profileUID, "external")
        XCTAssertFalse(backend.events.contains(where: { $0.hasPrefix("restore-profile:") }))
    }

    func testTerminationAfterActivationOnlyRestoresDNS() {
        let backend = ModeBackend()
        var exiting = false
        backend.didActivate = { exiting = true }
        let result = ClashModeTransactionEngine(backend: backend, interrupted: { exiting }).apply(.unifiedEgress)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(backend.state.profileUID, "unified")
        XCTAssertFalse(backend.events.contains(where: { $0.hasPrefix("restore-profile:") }))
        XCTAssertTrue(backend.events.contains("dns-release"))
    }

    func testOriginalNetworkReleasesDNSBeforeDisablingClashAndKeepsProfile() {
        let backend = ModeBackend(); backend.state = ModeBackend.runtime(uid: "unified", tun: true, proxy: true); backend.lease = ModeBackend.owned
        let result = ClashModeTransactionEngine(backend: backend).apply(.originalNetwork)
        XCTAssertTrue(result.verified, result.reason ?? "")
        XCTAssertEqual(backend.state.profileUID, "unified")
        XCTAssertFalse(backend.state.tunEnabled); XCTAssertFalse(backend.state.systemProxyEnabled)
        XCTAssertLessThan(backend.events.firstIndex(of: "dns-release")!, backend.events.firstIndex(of: "switches")!)
        XCTAssertFalse(backend.events.contains(where: { $0.hasPrefix("activate:") }))
    }

    func testExternalDNSOwnershipBlocksSwitch() {
        let backend = ModeBackend()
        backend.lease = .init(protocolVersion: 7, dnsLeaseState: "conflict", dnsLeaseOwnerPID: nil, dnsLeaseServices: 1, reason: "external DNS edit")
        let result = ClashModeTransactionEngine(backend: backend).apply(.companyCoexistence)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(backend.events.contains("dns-acquire"))
        XCTAssertFalse(backend.events.contains("dns-release"))
    }

    func testManagedModeNeedsTCPAndUDPDNSHijack() {
        let backend = ModeBackend(); backend.missingTCP = true
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(backend.events.contains("dns-acquire"))
    }

    func testManifestRejectsPathTraversalAndDuplicateIdentity() throws {
        let entry = ClashModeManifest.Entry(id: "company-coexistence", profileUID: "coexist", profileFile: "../bad.yaml", displayName: "公司共存", sourceSHA256: String(repeating: "a", count: 64), ruleMarker: "DOMAIN,netbar-mode-coexistence.invalid,DIRECT", targetGroup: "🧲 Claude")
        let manifest = ClashModeManifest(schemaVersion: 1, configRoot: "/tmp", modes: [entry, entry])
        XCTAssertThrowsError(try manifest.entry(for: .companyCoexistence))
    }

    func testDirectAndSelectorCycleCannotCountAsRealLeaf() {
        let state = ClashModeRuntime(profileUID: "x", tunEnabled: true, systemProxyEnabled: true, runtimeRuleMode: true, markers: [], selectors: ["a": "b", "b": "a", "c": "DIRECT"], members: ["a": ["b"], "b": ["a"], "c": ["DIRECT"]], proxyTypes: ["DIRECT": "Direct"], hijacksUDPAndTCP: true, ipv6Enabled: true)
        XCTAssertNil(state.leaf(for: "a")); XCTAssertNil(state.leaf(for: "c"))
    }

    func testOwnedDNSWithExternalTunOffNeverClaimsOriginalNetwork() {
        let backend = ModeBackend(); backend.state = ModeBackend.runtime(uid: "unified", tun: false, proxy: false); backend.lease = ModeBackend.owned
        let result = ClashModeTransactionEngine(backend: backend).observe()
        XCTAssertEqual(result.mode, .unifiedEgress)
        XCTAssertEqual(result.headline, "DNS 仍接管，流量接管不完整")
        XCTAssertTrue(result.manualPending)
        XCTAssertFalse(backend.events.contains("dns-acquire"))
    }

    func testActivationAppliedThenThrowsRestoresOriginal() {
        let backend = ModeBackend(); backend.failAfterActivate = true
        let original = backend.state
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified); XCTAssertFalse(result.manualPending, result.reason ?? "")
        XCTAssertEqual(backend.state.controlFingerprint, original.controlFingerprint)
    }

    func testPartialTunSwitchThenProxyFailureRollsBack() {
        let backend = ModeBackend(); backend.failAfterTun = true
        let original = backend.state
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified); XCTAssertFalse(result.manualPending, result.reason ?? "")
        XCTAssertEqual(backend.state.controlFingerprint, original.controlFingerprint)
        XCTAssertFalse(backend.events.contains("dns-acquire"))
    }

    func testPartialAcquireReleasesNewLeaseAndRestoresClash() {
        let backend = ModeBackend(); backend.failAfterAcquire = true
        let original = backend.state
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified); XCTAssertFalse(result.manualPending, result.reason ?? "")
        XCTAssertEqual(backend.lease.dnsLeaseState, "inactive")
        XCTAssertEqual(backend.state.controlFingerprint, original.controlFingerprint)
        XCTAssertTrue(backend.events.contains("dns-release"))
    }

    func testLostOriginalOwnedJournalCannotBeRecapturedDuringRollback() {
        let backend = ModeBackend(); backend.lease = ModeBackend.owned; backend.failSystemHTTPS = true
        backend.didActivate = { backend.lease = .init(protocolVersion: 7, dnsLeaseState: "inactive", dnsLeaseOwnerPID: nil, dnsLeaseServices: 0, reason: nil) }
        let original = backend.state
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified); XCTAssertTrue(result.manualPending)
        XCTAssertEqual(backend.state.controlFingerprint, original.controlFingerprint)
        XCTAssertEqual(backend.events.filter { $0 == "dns-prepare" }.count, 1)
    }

    func testConflictCanBeAcknowledgedByExplicitOriginalNetworkOnly() {
        let backend = ModeBackend(); backend.state = ModeBackend.runtime(uid: "unified", tun: true, proxy: true)
        backend.lease = .init(protocolVersion: 7, dnsLeaseState: "conflict", dnsLeaseOwnerPID: nil, dnsLeaseServices: 1, reason: "external DNS edit")
        let result = ClashModeTransactionEngine(backend: backend).apply(.originalNetwork)
        XCTAssertTrue(result.verified, result.reason ?? "")
        XCTAssertEqual(backend.lease.dnsLeaseState, "inactive")
    }

    func testSameUIDDNSDriftUsesNativeReactivation() {
        let backend = ModeBackend(); backend.state = ModeBackend.runtime(uid: "unified", tun: true, proxy: true); backend.state.dnsSHA256 = "changed"
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertTrue(result.verified, result.reason ?? "")
        XCTAssertTrue(backend.events.contains("activate:unified"))
    }

    func testExternalChangeDuringRollbackStopsFurtherWrites() {
        let backend = ModeBackend(); backend.failSystemHTTPS = true
        backend.didRestore = { backend.state = ModeBackend.runtime(uid: "original", tun: true, proxy: true, leaf: "Node B") }
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified); XCTAssertTrue(result.manualPending)
        XCTAssertEqual(backend.state.leaf(for: "🌐 统一出口"), "Node B")
        XCTAssertEqual(backend.events.filter { $0 == "switches" }.count, 1)
    }

    func testFinalReadFailureCannotProduceVerifiedSuccess() {
        let backend = ModeBackend()
        backend.didClose = { backend.runtimeUnavailable = true }
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified); XCTAssertTrue(result.manualPending)
        XCTAssertNotNil(result.reason)
    }

    func testFinalLeaseReleaseCannotProduceVerifiedSuccess() {
        let backend = ModeBackend()
        backend.didClose = { backend.lease = .init(protocolVersion: 7, dnsLeaseState: "inactive", dnsLeaseOwnerPID: nil, dnsLeaseServices: 0, reason: nil) }
        let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.reason?.contains("最终回读时 DNS") == true)
    }

    func testRuntimeExtraTunBypassAndAutomaticDirectFallbackAreRejected() {
        for problem in ["tun", "rules", "dns", "fallback"] {
            let backend = ModeBackend(); backend.activatedProblem = problem
            let result = ClashModeTransactionEngine(backend: backend).apply(.unifiedEgress)
            XCTAssertFalse(result.verified, problem)
            XCTAssertFalse(backend.events.contains("dns-acquire"), problem)
        }
    }

    func testFreshDNSLogsCannotBeReplacedWithOldQueriesOrUncorrelatedConnections() throws {
        func event(_ name: String, _ upstream: String) -> String { "{\"type\":\"debug\",\"payload\":\"[DNS] \(name) --> [] TXT from https://\(upstream):443/dns-query\"}" }
        let names = ["netbar-new-udp.claude.ai", "netbar-new-tcp.claude.ai"]
        XCTAssertNil(ClashDNSPathEvidence.freshUpstreams(logs: event("netbar-old.claude.ai", "1.1.1.1"), names: names))
        XCTAssertNil(ClashDNSPathEvidence.freshUpstreams(logs: event(names[0], "1.1.1.1"), names: names))
        let upstreams = try XCTUnwrap(ClashDNSPathEvidence.freshUpstreams(logs: event(names[0], "1.1.1.1") + "\n" + event(names[1], "1.0.0.1"), names: names))
        let good = [connection(ip: "1.1.1.1"), connection(ip: "1.0.0.1")]
        XCTAssertTrue(ClashDNSPathEvidence.confirmsChains(good, upstreams: upstreams, group: "🧲 Claude", leaf: "Node A"))
        XCTAssertFalse(ClashDNSPathEvidence.confirmsChains(good + [connection(ip: "1.1.1.1", leaf: "Old Node")], upstreams: upstreams, group: "🧲 Claude", leaf: "Node A"))
        XCTAssertNil(ClashDNSPathEvidence.freshUpstreams(logs: event(names[0], "223.5.5.5") + "\n" + event(names[1], "1.0.0.1"), names: names))
    }

    func testConnectionDeletionBoundariesKeepPrivateAndUnrelatedDNSConnections() throws {
        XCTAssertTrue(ClashDNSPathEvidence.isManagedDoH(connection(ip: "1.1.1.1")))
        XCTAssertFalse(ClashDNSPathEvidence.isManagedDoH(connection(ip: "1.1.1.1", group: "Other group")))
        XCTAssertFalse(ClashDNSPathEvidence.isManagedDoH(connection(ip: "1.1.1.1", port: "853")))
        for ip in ["127.0.0.1", "172.21.180.176", "192.168.1.3", "100.100.1.2", "fd7a:115c:a1e0::1", "fe80::1"] {
            XCTAssertFalse(ClashDNSPathEvidence.isAffectedPublicConnection(connection(ip: ip)), ip)
        }
        XCTAssertTrue(ClashDNSPathEvidence.isAffectedPublicConnection(connection(ip: "8.8.8.8")))
        for ip in ["192.200.0.23", "199.165.136.10", "119.45.14.85"] {
            XCTAssertFalse(ClashDNSPathEvidence.isAffectedPublicConnection(connection(ip: ip), protectedCIDRs: ["192.200.0.0/24", "199.165.136.0/24", "119.45.14.85/32"]))
        }
        let valid: [String: Any] = ["inet4-route-exclude-address": ["10.0.0.0/8"], "strict-route": true]
        XCTAssertEqual(try ClashDNSPathEvidence.tunCaptureSHA256(valid), try ClashDNSPathEvidence.tunCaptureSHA256(valid.merging(["exclude-interface": NSNull()]) { _, new in new }))
        XCTAssertNotEqual(try ClashDNSPathEvidence.tunCaptureSHA256(valid), try ClashDNSPathEvidence.tunCaptureSHA256(valid.merging(["exclude-interface": ["en0"]]) { _, new in new }))
    }

    func testOptInInstalledManifestReadOnly() throws {
        guard ProcessInfo.processInfo.environment["NETBAR_VALIDATE_LIVE_MANIFEST"] == "1" else { throw XCTSkip("Explicit local read-only manifest verification") }
        let backend = LiveClashNetworkModeBackend()
        let manifest = try backend.manifest()
        for mode in [ClashNetworkMode.companyCoexistence, .unifiedEgress] {
            let entry = try manifest.entry(for: mode)
            XCTAssertEqual(Set(entry.expectedTunCaptureKeys ?? []), Set(ClashTunPolicy.captureKeys))
            XCTAssertNotNil(entry.expectedTunCaptureSHA256)
        }
        let runtime = try backend.runtime()
        XCTAssertFalse(runtime.profileUID.isEmpty)
        XCTAssertEqual(runtime.rulesSHA256.count, 64)
        XCTAssertEqual(runtime.dnsSHA256.count, 64)
    }

    private func connection(ip: String, group: String = "🧲 Claude", leaf: String = "Node A", port: String = "443") -> [String: Any] {
        ["id": UUID().uuidString, "metadata": ["destinationIP": ip, "destinationPort": port, "specialProxy": group], "chains": [leaf, group]]
    }
}

private final class ModeBackend: ClashNetworkModeBackend {
    static let owned = ClashDNSLeaseStatus(protocolVersion: 7, dnsLeaseState: "owned", dnsLeaseOwnerPID: Int(ProcessInfo.processInfo.processIdentifier), dnsLeaseServices: 2, reason: nil)
    static let policy = ClashTunPolicy(autoRoute: true, autoDetectInterface: true, strictRoute: true, dnsHijack: ["any:53", "tcp://any:53"], routeExcludeAddress: ["10.0.0.0/8"])
    var state = runtime(uid: "original", tun: false, proxy: true)
    var lease = ClashDNSLeaseStatus(protocolVersion: 7, dnsLeaseState: "inactive", dnsLeaseOwnerPID: nil, dnsLeaseServices: 0, reason: nil)
    var events: [String] = []
    var companyBlocked = false, failSystemHTTPS = false, externalChangeOnVerify = false, missingTCP = false
    var failAfterActivate = false, failAfterTun = false, failAfterAcquire = false
    var runtimeUnavailable = false
    var activatedProblem: String?
    var didActivate: (() -> Void)?
    var didRestore: (() -> Void)?, didClose: (() -> Void)?
    static func runtime(uid: String, tun: Bool, proxy: Bool, leaf: String = "Node A", tcp: Bool = true) -> ClashModeRuntime {
        .init(profileUID: uid, tunEnabled: tun, systemProxyEnabled: proxy, runtimeRuleMode: true,
              markers: ["DOMAIN,netbar-mode-unified.invalid,🌐 统一出口", "DOMAIN,netbar-mode-coexistence.invalid,DIRECT"],
              selectors: ["♻️ 手动切换": "Node A", "🧲 Claude": "Node A", "🌐 统一出口": leaf],
              members: ["♻️ 手动切换": ["Node A", "Node B"], "🧲 Claude": ["Node A", "Node B"], "🌐 统一出口": ["Node A", "Node B"]],
              proxyTypes: ["Node A": "Vless", "Node B": "Shadowsocks", "♻️ 手动切换": "Selector", "🧲 Claude": "Selector", "🌐 统一出口": "Selector"], hijacksUDPAndTCP: tcp, ipv6Enabled: uid == "unified", rulesSHA256: String(repeating: "c", count: 64), dnsSHA256: "dns", tunPolicy: Self.policy, tunCaptureSHA256: "capture")
    }
    func manifest() throws -> ClashModeManifest {
        events.append("manifest")
        return .init(schemaVersion: 1, configRoot: "/tmp/clash", modes: [
            .init(id: "company-coexistence", profileUID: "coexist", profileFile: "coexist.yaml", displayName: "公司共存", sourceSHA256: String(repeating: "a", count: 64), ruleMarker: "DOMAIN,netbar-mode-coexistence.invalid,DIRECT", targetGroup: "🧲 Claude", expectedRulesSHA256: String(repeating: "c", count: 64), expectedIPv6: false, expectedDNSSHA256: "dns", expectedTunPolicy: Self.policy, expectedTunCaptureKeys: ClashTunPolicy.captureKeys, expectedTunCaptureSHA256: "capture"),
            .init(id: "unified-egress", profileUID: "unified", profileFile: "unified.yaml", displayName: "统一出口", sourceSHA256: String(repeating: "b", count: 64), ruleMarker: "DOMAIN,netbar-mode-unified.invalid,🌐 统一出口", targetGroup: "🌐 统一出口", expectedRulesSHA256: String(repeating: "c", count: 64), expectedIPv6: true, expectedDNSSHA256: "dns", expectedTunPolicy: Self.policy, expectedTunCaptureKeys: ClashTunPolicy.captureKeys, expectedTunCaptureSHA256: "capture", expectedUnifiedMembersSHA256: Self.runtime(uid: "unified", tun: true, proxy: true).membersSHA256("🌐 统一出口"))
        ])
    }
    func runtime() throws -> ClashModeRuntime { events.append("runtime"); if runtimeUnavailable { throw ClashModeFailure("runtime unavailable") }; return state }
    func dnsStatus() throws -> ClashDNSLeaseStatus { events.append("dns-status"); return lease }
    func assertCompanyVPNDisconnected() throws { events.append("company-gate"); if companyBlocked { throw ClashModeFailure("company tunnel active") } }
    func activate(_ entry: ClashModeManifest.Entry) throws {
        events.append("activate:" + entry.profileUID); state = Self.runtime(uid: entry.profileUID, tun: state.tunEnabled, proxy: state.systemProxyEnabled, tcp: !missingTCP)
        if activatedProblem == "tun" { state.tunCaptureSHA256 = "altered" }
        if activatedProblem == "rules" { state.rulesSHA256 = "altered" }
        if activatedProblem == "dns" { state.dnsSHA256 = "altered" }
        if activatedProblem == "disabled-rule" { state.disabledRuleCount = 1 }
        if activatedProblem == "fallback" {
            state = .init(profileUID: state.profileUID, tunEnabled: state.tunEnabled, systemProxyEnabled: state.systemProxyEnabled, runtimeRuleMode: true, markers: state.markers, selectors: state.selectors, members: state.members, proxyTypes: ["🌐 统一出口": "Fallback", "Node A": "Vless", "Node B": "Direct"], hijacksUDPAndTCP: true, ipv6Enabled: true, rulesSHA256: state.rulesSHA256, dnsSHA256: state.dnsSHA256, tunPolicy: state.tunPolicy)
        }
        didActivate?()
        if failAfterActivate { failAfterActivate = false; throw ClashModeFailure("activation timed out after apply") }
    }
    func restoreProfile(_ uid: String) throws { events.append("restore-profile:" + uid); state = Self.runtime(uid: uid, tun: state.tunEnabled, proxy: state.systemProxyEnabled); didRestore?() }
    func setNativeTunPolicy(_ policy: ClashTunPolicy) throws { events.append("tun-policy") }
    func setNativeSwitch(tun: Bool, proxy: Bool) throws {
        events.append("switches")
        if failAfterTun { failAfterTun = false; state = Self.runtime(uid: state.profileUID, tun: tun, proxy: state.systemProxyEnabled); throw ClashModeFailure("system proxy failed") }
        let capture = state.tunCaptureSHA256, dns = state.dnsSHA256
        state = Self.runtime(uid: state.profileUID, tun: tun, proxy: proxy, leaf: state.selectors["🌐 统一出口"]!, tcp: !missingTCP)
        state.tunCaptureSHA256 = capture; state.dnsSHA256 = dns
    }
    func select(group: String, node: String) throws {
        events.append("select")
        let old = state
        state = Self.runtime(uid: state.profileUID, tun: state.tunEnabled, proxy: state.systemProxyEnabled, leaf: node, tcp: !missingTCP)
        state.tunCaptureSHA256 = old.tunCaptureSHA256; state.dnsSHA256 = old.dnsSHA256; state.rulesSHA256 = old.rulesSHA256; state.tunPolicy = old.tunPolicy
    }
    func prepareDNS() throws {
        events.append("dns-prepare")
        lease = .init(protocolVersion: 7, dnsLeaseState: "preparing", dnsLeaseOwnerPID: Int(ProcessInfo.processInfo.processIdentifier), dnsLeaseServices: 0, reason: nil)
    }
    func acquireDNS() throws { events.append("dns-acquire"); guard ["preparing", "owned"].contains(lease.dnsLeaseState) else { throw ClashModeFailure("original journal missing") }; lease = Self.owned; if failAfterAcquire { failAfterAcquire = false; throw ClashModeFailure("acquire timed out after write") } }
    func releaseDNS() throws { events.append("dns-release"); lease = .init(protocolVersion: 7, dnsLeaseState: "inactive", dnsLeaseOwnerPID: nil, dnsLeaseServices: 0, reason: nil) }
    func verifyDNSPath(mode: ClashNetworkMode, entry: ClashModeManifest.Entry, leaf: String) throws {
        events.append("verify-dns")
        if externalChangeOnVerify { state = Self.runtime(uid: "external", tun: true, proxy: false); throw ClashModeFailure("external change") }
    }
    func verifySystemHTTPS() throws { events.append("verify-https"); if failSystemHTTPS { throw ClashModeFailure("HTTPS failed") } }
    func closeConnections() { events.append("close-connections"); didClose?() }
}
#endif
