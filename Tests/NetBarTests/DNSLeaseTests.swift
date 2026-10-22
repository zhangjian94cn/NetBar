import XCTest
import NetBarDNSLeaseSupport

final class DNSLeaseTests: XCTestCase {
    private let owner = DNSProcessIdentity(pid: 21, uid: 501, startSeconds: 100, startMicroseconds: 3, executable: "NetBar")
    private let clash = DNSProcessIdentity(pid: 22, uid: 501, startSeconds: 100, startMicroseconds: 4, executable: "Clash")
    private func automatic() throws -> DNSSettings { try .init(configuration: nil) }
    private func manual(_ values: [String]) throws -> DNSSettings {
        try .init(configuration: ["ServerAddresses": values, "SearchDomains": ["home.example"]])
    }
    private func service(_ id: String, settings: DNSSettings, active: Bool = true) -> DNSService {
        .init(id: id, name: id, device: id == "wifi" ? "en0" : "bridge0", active: active, settings: settings)
    }

    func testOldOutcomeDoesNotDowngradeCurrentHelperProtocolOrEraseConflict() throws {
        let backend = FakeDNSBackend([service("wifi", settings: try automatic())])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        store.result = try JSONDecoder().decode(DNSLeaseStatus.self, from: Data(#"{"protocolVersion":6,"dnsLeaseState":"conflict","dnsLeaseServices":0,"reason":"external change"}"#.utf8))
        let status = try engine.status()
        XCTAssertEqual(status.protocolVersion, 7)
        XCTAssertEqual(status.dnsLeaseState, "conflict")
        XCTAssertEqual(status.reason, "external change")
        XCTAssertThrowsError(try engine.prepare(owner: owner, clash: clash))
        XCTAssertTrue(backend.writes.isEmpty)
        _ = try engine.release()
        XCTAssertEqual(try engine.status().protocolVersion, 7)
    }

    func testSchemaOneJournalWithoutPreparationKeysRetainsChecksumBytes() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let lease = DNSLease(owner: owner, clash: clash)
        let oldBytes = try encoder.encode(lease)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        XCTAssertNil(fields["activationDeadline"])
        XCTAssertNil(fields["recoveryNotBefore"])
        let restored = try JSONDecoder().decode(DNSLease.self, from: oldBytes)
        XCTAssertEqual(try encoder.encode(restored), oldBytes)
    }

    func testPreparationCapturesBeforeClashPlaceholderWithoutWriting() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        XCTAssertEqual(try engine.prepare(owner: owner, clash: clash).dnsLeaseState, "preparing")
        XCTAssertTrue(backend.writes.isEmpty)
        // Native Fake-IP activation writes the same placeholder before NetBar acquires.
        backend.current[0] = service("wifi", settings: try original.managed())
        XCTAssertEqual(try engine.acquire(owner: owner, clash: clash).dnsLeaseState, "owned")
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(store.lease?.records[0].original, original)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        XCTAssertEqual(store.lease?.records[0].original, original)
        _ = try engine.release()
        XCTAssertEqual(backend.current[0].settings, original)
    }

    func testMissingOrExpiredPreparationCannotAcquire() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store, now: { clock })
        XCTAssertThrowsError(try engine.acquire(owner: owner, clash: clash))
        _ = try engine.prepare(owner: owner, clash: clash)
        let deadline = store.lease?.activationDeadline
        clock = clock.addingTimeInterval(60)
        _ = try engine.prepare(owner: owner, clash: clash)
        XCTAssertEqual(store.lease?.activationDeadline, deadline)
        clock = clock.addingTimeInterval(61)
        XCTAssertThrowsError(try engine.acquire(owner: owner, clash: clash))
        XCTAssertTrue(backend.writes.isEmpty)
        _ = try engine.reconcile()
        XCTAssertNotNil(store.lease)
        clock = clock.addingTimeInterval(6)
        XCTAssertEqual(try engine.reconcile().dnsLeaseState, "inactive")
    }

    func testMidPreparationCrashWaitsForClashDNSScriptThenRestores() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store, now: { clock })
        _ = try engine.prepare(owner: owner, clash: clash)
        backend.dead.insert(owner.pid)
        _ = try engine.reconcile()
        XCTAssertNotNil(store.lease)
        // An already-dispatched Clash script finishes after NetBar exits.
        backend.current[0] = service("wifi", settings: try original.managed())
        clock = clock.addingTimeInterval(5)
        _ = try engine.reconcile()
        XCTAssertTrue(backend.writes.isEmpty)
        clock = clock.addingTimeInterval(2)
        XCTAssertEqual(try engine.reconcile().dnsLeaseState, "inactive")
        XCTAssertEqual(backend.current[0].settings, original)
    }

    func testUnknownPlaceholderBaselineCannotBeSilentlyAdopted() throws {
        let backend = FakeDNSBackend([service("wifi", settings: try automatic().managed())])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        XCTAssertThrowsError(try engine.prepare(owner: owner, clash: clash))
        XCTAssertNil(store.lease)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testNewNetworkPlaceholderWithoutOriginalIsNotAdopted() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        backend.current.append(service("bridge", settings: try original.managed()))
        XCTAssertThrowsError(try engine.reconcile())
        XCTAssertEqual(store.lease?.records.count, 1)
        XCTAssertEqual(try engine.status().dnsLeaseState, "conflict")
    }

    func testNewPhysicalUUIDDuringPreparationIsRejectedWithoutAdoption() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        backend.current.append(service("bridge", settings: original))
        XCTAssertThrowsError(try engine.acquire(owner: owner, clash: clash))
        XCTAssertEqual(store.lease?.records.count, 1)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testAutomaticRestoresAutomaticRatherThanCachedDHCPServer() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        XCTAssertEqual(try engine.acquire(owner: owner, clash: clash).dnsLeaseState, "owned")
        XCTAssertEqual(try backend.current[0].settings.configuration()?["ServerAddresses"] as? [String], DNSLease.managedServers)
        XCTAssertEqual(try engine.release().dnsLeaseState, "inactive")
        XCTAssertNil(try backend.current[0].settings.configuration())
    }

    func testManualConfigurationAndServerOrderingRoundTripExactly() throws {
        let original = try manual(["9.9.9.9", "8.8.8.8"])
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let engine = DNSLeaseEngine(backend: backend, store: MemoryDNSStore())
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        XCTAssertEqual(try backend.current[0].settings.configuration()?["SearchDomains"] as? [String], ["home.example"])
        _ = try engine.release()
        XCTAssertEqual(backend.current[0].settings, original)
        XCTAssertEqual(try backend.current[0].settings.configuration()?["ServerAddresses"] as? [String], ["9.9.9.9", "8.8.8.8"])
    }

    func testModeSwitchRetainsFirstBaselineAndDoesNotWriteAgain() throws {
        let original = try manual(["8.8.4.4"])
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        let id = store.lease?.id
        _ = try engine.acquire(owner: owner, clash: clash)
        XCTAssertEqual(store.lease?.id, id)
        XCTAssertEqual(store.lease?.records.first?.original, original)
        XCTAssertEqual(backend.writes.count, 1)
    }

    func testExternalChangeIsPreservedWhileOtherServicesRestore() throws {
        let original = try automatic(); let external = try manual(["10.1.2.3"])
        let backend = FakeDNSBackend([service("wifi", settings: original), service("bridge", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        backend.current[0] = service("wifi", settings: external)
        XCTAssertEqual(try engine.status().dnsLeaseState, "conflict")
        XCTAssertEqual(try engine.release().dnsLeaseState, "conflict")
        XCTAssertEqual(backend.current[0].settings, external)
        XCTAssertEqual(backend.current[1].settings, original)
        XCTAssertNil(store.lease)
        XCTAssertEqual(store.finished?.records.first?.disposition, .conflict)
    }

    func testPartialAcquireKeepsOriginalsUntilNativeRollbackThenRelease() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original), service("bridge", settings: original)])
        backend.failService = "bridge"
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        XCTAssertThrowsError(try engine.acquire(owner: owner, clash: clash))
        XCTAssertEqual(backend.current[0].settings, try original.managed())
        XCTAssertNotNil(store.lease)
        backend.failService = nil
        _ = try engine.release()
        XCTAssertEqual(backend.current.map(\.settings), [original, original])
        XCTAssertNil(store.lease)
    }

    func testCrashAfterWriteBeforeCommitRecoversWriteAheadRecord() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        store.lease?.records[0].disposition = .prepared
        backend.dead.insert(owner.pid)
        XCTAssertEqual(try engine.reconcile().dnsLeaseState, "inactive")
        XCTAssertEqual(backend.current[0].settings, original)
    }

    func testClashExitOnlyRestoresDNSAndNewAppCannotAdoptOldLease() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        let replacement = DNSProcessIdentity(pid: owner.pid, uid: owner.uid, startSeconds: 110, startMicroseconds: 0, executable: "NetBar")
        XCTAssertThrowsError(try engine.acquire(owner: replacement, clash: clash))
        backend.dead.insert(clash.pid)
        _ = try engine.reconcile()
        XCTAssertEqual(backend.current[0].settings, original)
        // Backend intentionally exposes DNS operations only: recovery cannot change Clash/VPN.
        XCTAssertEqual(backend.writes.count, 2)
    }

    func testNetworkChangeRestoresInactiveAndAcquiresNewServiceByUUID() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        let oldManaged = backend.current[0].settings
        backend.current = [service("wifi", settings: oldManaged, active: false), service("bridge", settings: original)]
        _ = try engine.reconcile()
        XCTAssertEqual(backend.current[0].settings, original)
        XCTAssertEqual(backend.current[1].settings, try original.managed())
        _ = try engine.release()
        XCTAssertEqual(backend.current.map(\.settings), [original, original])
    }

    func testRemovedServiceRemainsPendingUntilSameUUIDReturns() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        let managed = backend.current[0]
        backend.current = []
        let pending = try engine.release()
        XCTAssertEqual(pending.dnsLeaseState, "conflict")
        XCTAssertEqual(pending.dnsLeaseServices, 1)
        XCTAssertNotNil(store.lease)
        backend.current = [managed]
        XCTAssertEqual(try engine.release().dnsLeaseState, "inactive")
    }

    func testCompareAndSetPreservesConcurrentChangeDuringWrite() throws {
        let original = try automatic(); let external = try manual(["10.0.0.53"])
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        backend.beforeFirstWrite = { backend.current[0] = self.service("wifi", settings: external) }
        let engine = DNSLeaseEngine(backend: backend, store: MemoryDNSStore())
        _ = try engine.prepare(owner: owner, clash: clash)
        XCTAssertThrowsError(try engine.acquire(owner: owner, clash: clash))
        XCTAssertEqual(backend.current[0].settings, external)
    }

    func testReadOnlyStatusDoesNotAcquireOrWrite() throws {
        let backend = FakeDNSBackend([service("wifi", settings: try automatic())])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        XCTAssertEqual(try engine.status().dnsLeaseState, "inactive")
        XCTAssertNil(store.lease); XCTAssertTrue(backend.writes.isEmpty)
    }

    func testCoreExitRestoresDNSAndDoesNotAutoBindReplacement() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        let core = DNSProcessIdentity(pid: 30, uid: 0, startSeconds: 101, startMicroseconds: 0, executable: "mihomo")
        _ = try engine.prepare(owner: owner, clash: clash, core: core)
        _ = try engine.acquire(owner: owner, clash: clash, core: core)
        backend.dead.insert(core.pid)
        XCTAssertEqual(try engine.reconcile().dnsLeaseState, "inactive")
        XCTAssertEqual(backend.current[0].settings, original)
        XCTAssertNil(store.lease)
    }

    func testExternalReturnToAutomaticIsNotImmediatelyReacquired() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let engine = DNSLeaseEngine(backend: backend, store: MemoryDNSStore())
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        backend.current[0] = service("wifi", settings: original)
        XCTAssertEqual(try engine.reconcile().dnsLeaseState, "conflict")
        XCTAssertEqual(backend.current[0].settings, original)
        XCTAssertEqual(backend.writes.count, 1)
    }

    func testExplicitReleaseAcknowledgesArchivedConflictAndNewModeUsesExternalBaseline() throws {
        let original = try automatic(); let external = try manual(["10.10.0.53"])
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        backend.current[0] = service("wifi", settings: external)
        XCTAssertEqual(try engine.release().dnsLeaseState, "conflict")
        XCTAssertThrowsError(try engine.acquire(owner: owner, clash: clash))
        let writes = backend.writes.count
        XCTAssertEqual(try engine.release().dnsLeaseState, "inactive")
        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertNotNil(store.finished)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        XCTAssertEqual(store.lease?.records[0].original, external)
        _ = try engine.release()
        XCTAssertEqual(backend.current[0].settings, external)
    }

    func testTUNPathLossRestoresDNSWhileOwnerAndCoreRemainAlive() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let store = MemoryDNSStore(); let engine = DNSLeaseEngine(backend: backend, store: store)
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        backend.interception = false
        let writes = backend.writes.count
        let observed = try engine.status()
        XCTAssertEqual(observed.dnsLeaseState, "conflict")
        XCTAssertTrue(observed.reason?.contains("TUN DNS interception ended") == true)
        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertNotNil(store.lease)
        XCTAssertEqual(try engine.reconcile().dnsLeaseState, "inactive")
        XCTAssertEqual(backend.current[0].settings, original)
        XCTAssertTrue(backend.dead.isEmpty)
        XCTAssertThrowsError(try engine.acquire(owner: owner, clash: clash))
        XCTAssertEqual(backend.writes.count, 2)
        XCTAssertNil(store.lease)
    }

    func testReusedTUNNameWithNewInterfaceIndexCannotRetainLease() throws {
        let original = try automatic()
        let backend = FakeDNSBackend([service("wifi", settings: original)])
        let engine = DNSLeaseEngine(backend: backend, store: MemoryDNSStore())
        _ = try engine.prepare(owner: owner, clash: clash)
        _ = try engine.acquire(owner: owner, clash: clash)
        backend.interceptionIndex = 100
        XCTAssertEqual(try engine.status().dnsLeaseState, "conflict")
        XCTAssertEqual(try engine.reconcile().dnsLeaseState, "inactive")
        XCTAssertEqual(backend.current[0].settings, original)
    }
}

private final class FakeDNSBackend: DNSLeaseBackend {
    var current: [DNSService]
    var dead = Set<Int32>()
    var writes: [String] = []
    var failService: String?
    var beforeFirstWrite: (() -> Void)?
    var interception = true
    var interceptionIndex: UInt32 = 99
    init(_ services: [DNSService]) { current = services }
    func services() throws -> [DNSService] { current }
    func isAlive(_ identity: DNSProcessIdentity) -> Bool { !dead.contains(identity.pid) }
    func interceptionIdentity(for lease: DNSLease) -> DNSInterceptionIdentity? {
        interception ? .init(device: "utun99", interfaceIndex: interceptionIndex) : nil
    }
    func replace(serviceID: String, expected: DNSSettings, with settings: DNSSettings) throws {
        if let callback = beforeFirstWrite { beforeFirstWrite = nil; callback() }
        guard let index = current.firstIndex(where: { $0.id == serviceID }), current[index].settings == expected else {
            throw DNSLeaseError.externalChange(serviceID)
        }
        if failService == serviceID { throw DNSLeaseError.writeFailed("injected failure") }
        let old = current[index]
        current[index] = .init(id: old.id, name: old.name, device: old.device, active: old.active, settings: settings)
        writes.append(serviceID)
    }
}

private final class MemoryDNSStore: DNSLeaseStoring {
    var lease: DNSLease?
    var finished: DNSLease?
    var result: DNSLeaseStatus?
    func load() throws -> DNSLease? { lease }
    func save(_ lease: DNSLease) throws { self.lease = lease }
    func finish(_ lease: DNSLease, status: DNSLeaseStatus) throws { finished = lease; self.lease = nil; result = status }
    func previousStatus() throws -> DNSLeaseStatus? { result }
    func acknowledgeConflict() throws { result = .init(state: "inactive") }
}
