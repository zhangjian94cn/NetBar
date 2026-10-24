import AppKit
import XCTest
@testable import NetBar

final class ManagementPanelsTests: XCTestCase {
    func testOnlyHTTPLinksWithoutEmbeddedCredentials() throws {
        for value in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.com", "https://example.com/?api_key=secret", "https://example.com/#token"] {
            XCTAssertThrowsError(try ManagementPanel(name: "Test", address: value).validatedURL())
        }
        XCTAssertEqual(try ManagementPanel(name: "Kiwi", address: "https://kiwivm.64clouds.com/?veid=123").validatedURL().host, "kiwivm.64clouds.com")
    }
    func testTunnelIsRestrictedToItsOwnLoopbackPort() {
        for value in ["http://example.com:8080", "http://127.0.0.1:8082", "http://127.0.0.1:8080/path", "http://127.0.0.1:8080/?next=remote"] {
            XCTAssertThrowsError(try ManagementPanel(name: "Test", address: value, access: .sub2apiBWG).validatedURL())
        }
        XCTAssertNoThrow(try ManagementPanel(name: "Test", address: "http://127.0.0.1:8080", access: .sub2apiBWG, tunnelScript: "/tmp/sub2api-tunnel.sh").validated())
        XCTAssertThrowsError(try ManagementPanel(name: "Test", address: "http://127.0.0.1:8080", access: .sub2apiBWG, tunnelScript: "/tmp/anything.sh").validated())
    }
    func testDefaultsDoNotLoadVPSPasswordOrChangeItsIdentity() {
        let config = AppConfig.VPSConfig(id: "fixture", name: "Test", host: "example.com", port: 2053, basePath: "panel", username: "admin", useTLS: true)
        let panels = ManagementPanel.defaults(configs: [config])
        XCTAssertEqual(panels.count, 2)
        XCTAssertEqual(panels[1].id, "vps-fixture")
        XCTAssertEqual(panels[1].username, "admin")
        XCTAssertEqual(panels[1].password, "")
        XCTAssertEqual(panels[1].credentialsSummary, "已保存账号 · 密码未保存")
    }
    @MainActor func testRoundTripAndDeletionThroughSingleSecureRecord() async throws {
        var data: Data?
        let store = ManagementPanelsStore(read: { data }, write: { data = $0 }, defaults: { [] })
        await store.load()
        let panel = ManagementPanel(name: "示例", address: "https://example.com", username: "test", password: "fixture-only")
        let saved = await store.save([panel]); XCTAssertTrue(saved)
        let reopened = ManagementPanelsStore(read: { data }, write: { data = $0 }, defaults: { [] })
        await reopened.load()
        XCTAssertEqual(reopened.panels.first?.password, "fixture-only")
        let deleted = await reopened.save([]); XCTAssertTrue(deleted)
        XCTAssertEqual(try JSONDecoder().decode([ManagementPanel].self, from: XCTUnwrap(data)), [])
    }
    @MainActor func testSaveFailurePreservesOriginalAndEditorInput() async {
        let original = ManagementPanel(name: "Original", address: "https://example.com")
        let data = try! JSONEncoder().encode([original])
        let store = ManagementPanelsStore(read: { data }, write: { _ in throw PanelError.unavailable })
        await store.load()
        let editor = ManagementPanelEditor(); _ = editor.select(original)
        editor.draft.password = "unsaved-fixture"
        let saved = await editor.save(store: store)
        XCTAssertFalse(saved); XCTAssertEqual(store.panels, [original])
        XCTAssertEqual(editor.draft.password, "unsaved-fixture"); XCTAssertTrue(editor.dirty)
    }
    @MainActor func testConcurrentExternalChangeBlocksOverwrite() async throws {
        var data: Data?
        var writes = 0
        let store = ManagementPanelsStore(read: { data }, write: { data = $0; writes += 1 }, defaults: { [] })
        await store.load()
        data = try JSONEncoder().encode([ManagementPanel(name: "External", address: "https://example.com")])
        let saved = await store.save([ManagementPanel(name: "Mine", address: "https://example.org")])
        XCTAssertFalse(saved); XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.message, PanelError.conflict.localizedDescription)
    }
    @MainActor func testCorruptAndLockedStorageCannotBeOverwritten() async {
        for reader in [{ () throws -> Data? in Data("broken".utf8) }, { () throws -> Data? in throw PanelError.unavailable }] {
            var writes = 0
            let store = ManagementPanelsStore(read: reader, write: { _ in writes += 1 })
            await store.load(); XCTAssertFalse(store.loaded)
            let saved = await store.save([]); XCTAssertFalse(saved); XCTAssertEqual(writes, 0)
        }
    }
    @MainActor func testInvalidDraftAndDuplicateIdentityCannotPersist() async {
        var writes = 0
        let store = ManagementPanelsStore(read: { nil }, write: { _ in writes += 1 }, defaults: { [] })
        await store.load()
        let bad = await store.save([ManagementPanel(name: "", address: "https://example.com")]); XCTAssertFalse(bad)
        let panel = ManagementPanel(name: "A", address: "https://example.com")
        let duplicate = await store.save([panel, panel]); XCTAssertFalse(duplicate); XCTAssertEqual(writes, 0)
    }
    @MainActor func testImportNeverOverwritesSavedCredentialsAndRejectsMalformedInput() async throws {
        let saved = ManagementPanel(id: "saved", name: "Saved", address: "https://example.com", password: "keep-this")
        var data: Data? = try JSONEncoder().encode([saved])
        let store = ManagementPanelsStore(read: { data }, write: { data = $0 })
        await store.load()
        var different = saved; different.password = "do-not-overwrite"
        let new = ManagementPanel(name: "New", address: "https://example.org", password: "new-fixture")
        let good = await store.importRecord(try JSONEncoder().encode([different, new]))
        XCTAssertTrue(good); XCTAssertEqual(store.panels.count, 2); XCTAssertEqual(store.panels[0].password, "keep-this")
        let before = data
        let bad = await store.importRecord(Data("broken".utf8))
        XCTAssertFalse(bad); XCTAssertEqual(data, before)
    }
    @MainActor func testCredentialClipboardExpiresOnlyOwnCopy() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        CredentialClipboard.copy("fixture", pasteboard: board, lifetime: 0.03)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(board.string(forType: .string))
        CredentialClipboard.copy("fixture", pasteboard: board, lifetime: 0.03)
        board.clearContents(); board.setString("user-new-copy", forType: .string)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(board.string(forType: .string), "user-new-copy")
    }
    func testCheckedKeychainUpdatesInPlaceAndReadsBack() throws {
        let key = "test_panel_\(UUID().uuidString)"
        defer { KeychainHelper.delete(key: key) }
        try KeychainHelper.writeChecked(key: key, data: Data("first".utf8))
        try KeychainHelper.writeChecked(key: key, data: Data("second".utf8))
        XCTAssertEqual(try KeychainHelper.readChecked(key: key), Data("second".utf8))
    }
    func testTunnelDelegationKeepsOwnerChildAndUsesFixedArguments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("sub2api-tunnel.sh")
        let pidFile = dir.appendingPathComponent("pid")
        let argsFile = dir.appendingPathComponent("args")
        // Fixture paths consist solely of a system temp path and UUID.
        try "sleep 30 >/dev/null 2>&1 &\necho $! > '\(pidFile.path)'\nprintf '%s\\n' \"$@\" > '\(argsFile.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        let passed = await ManagementTunnelLauncher.run(script: script.path, host: "bwg", timeout: 2)
        XCTAssertTrue(passed)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGTERM) }
        XCTAssertEqual(kill(pid, 0), 0, "Delegated service child must survive launcher exit")
        XCTAssertEqual(try String(contentsOf: argsFile), "--host\nbwg\nup\n--no-open\n")
        let refused = await ManagementTunnelLauncher.run(script: script.path, host: "unregistered", timeout: 2)
        XCTAssertFalse(refused)
    }
}
