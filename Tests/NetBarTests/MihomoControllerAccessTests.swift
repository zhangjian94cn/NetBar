import Foundation
import NetworkExecution
import XCTest
@testable import NetBar

final class MihomoControllerAccessTests: XCTestCase {
    private let modern = "/var/run/clash-verge-service/users/702/verge-mihomo.sock"
    private let legacy = "/tmp/verge/verge-mihomo.sock"
    private let config = "{\"mixed-port\":7897,\"tun\":{\"enable\":true}}\n200"

    func testDefaultDiscoversCurrentUserServiceWithoutLegacyPort() throws {
        var calls: [[String]] = []
        let access = makeAccess { args in
            calls.append(args)
            return (0, self.config)
        }
        let session = try access.resolve().get()
        XCTAssertEqual(session.endpoint, .unixSocket(modern))
        XCTAssertEqual(session.configuration.mixedPort, 7897)
        XCTAssertTrue(session.configuration.tunEnabled)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains("--noproxy"))
    }

    func testInvalidModernResponseFallsBackToValidatedLegacySocket() throws {
        var calls: [[String]] = []
        let access = makeAccess { args in
            calls.append(args)
            return (0, args.contains(self.modern) ? "not a config\n200" : self.config)
        }
        XCTAssertEqual(try access.resolve().get().endpoint, .unixSocket(legacy))
        XCTAssertEqual(calls.count, 2)
    }

    func testMissingSocketsUseDefaultHTTPForReads() throws {
        let access = makeAccess { args in
            args.contains("--unix-socket") ? (7, "\n000") : (0, self.config)
        }
        XCTAssertEqual(try access.resolve().get().endpoint, .http("http://127.0.0.1:9097/connections"))
    }

    func testSavedLegacyDefaultMigratesButCustomSocketIsExclusive() throws {
        var settings = settings(socket: legacy)
        var calls: [[String]] = []
        let access = MihomoControllerAccess(settings: { settings }, userID: 702) { args in
            calls.append(args)
            return args.contains("/custom.sock") ? (7, "\n000") : (0, self.config)
        }
        XCTAssertEqual(try access.resolve().get().endpoint, .unixSocket(modern))
        settings.socketPath = "/custom.sock"
        calls.removeAll()
        XCTAssertThrowsError(try access.resolve().get())
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains("/custom.sock"))
        settings.socketPath = ""
        XCTAssertEqual(try access.resolve().get().endpoint, .unixSocket(modern))
    }

    func testCustomHTTPIsExclusiveAndAuthenticationFailureIsActionable() {
        var calls: [[String]] = []
        let access = makeAccess(controller: "http://127.0.0.1:9999/connections") { args in
            calls.append(args)
            return (0, "{\"message\":\"unauthorized\"}\n401")
        }
        XCTAssertThrowsError(try access.resolve().get())
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].contains("--unix-socket"))
        XCTAssertTrue(access.failureDescription.contains("认证"))
        XCTAssertFalse(access.failureDescription.contains("secret-value"))
    }

    func testFailureIsRetryableWithinRoundAndSuccessExpiresNextRound() throws {
        var healthyModern = false
        var calls = 0
        let access = makeAccess { args in
            calls += 1
            if healthyModern && args.contains(self.modern) { return (0, self.config) }
            return (7, "\n000")
        }
        try ProbeContext.withValue(ProbeContext(timeout: 10)) {
            XCTAssertThrowsError(try access.resolve().get())
            healthyModern = true
            XCTAssertEqual(try access.resolve().get().endpoint, .unixSocket(modern))
            let before = calls
            _ = try access.resolve().get()
            XCTAssertEqual(calls, before)
        }
        healthyModern = false
        try ProbeContext.withValue(ProbeContext(timeout: 10)) {
            XCTAssertThrowsError(try access.resolve().get())
        }
    }

    func testAllCandidatesShareBudgetAndRespectParentCancellation() throws {
        var contexts: [ProbeContext] = []
        let access = makeAccess { _ in
            if let context = ProbeContext.current { contexts.append(context) }
            return (7, "\n000")
        }
        let parent = ProbeContext(timeout: 0.5)
        try ProbeContext.withValue(parent) { XCTAssertThrowsError(try access.resolve().get()) }
        XCTAssertEqual(contexts.count, 3)
        XCTAssertTrue(contexts.allSatisfy { $0 === contexts.first! && $0.deadline <= parent.deadline })
        parent.cancel()
        let before = contexts.count
        try ProbeContext.withValue(parent) { XCTAssertThrowsError(try access.resolve().get()) }
        XCTAssertEqual(contexts.count, before)
        let expired = ProbeContext(timeout: 0)
        try ProbeContext.withValue(expired) { XCTAssertThrowsError(try access.resolve().get()) }
        XCTAssertEqual(contexts.count, before)
    }

    func testFailedWriteNeverMovesToAnotherEndpoint() {
        var calls: [[String]] = []
        let access = makeAccess { args in
            calls.append(args)
            return args.contains("DELETE") ? (7, "\n000") : (0, self.config)
        }
        XCTAssertFalse(access.write(method: "DELETE", path: "/connections"))
        #if !APP_STORE
        XCTAssertEqual(calls.filter { $0.contains("DELETE") }.count, 1)
        XCTAssertTrue(calls.allSatisfy { $0.contains(modern) })
        #else
        XCTAssertTrue(calls.isEmpty)
        #endif
    }

    func testHTTPRemainsReadOnlyAndUnverifiedEndpointNeverReceivesWrite() {
        var calls: [[String]] = []
        let access = makeAccess(controller: "http://127.0.0.1:9999") { args in
            calls.append(args)
            return (0, self.config)
        }
        XCTAssertFalse(access.write(method: "PATCH", path: "/configs", body: "{}"))
        XCTAssertFalse(calls.contains { $0.contains("PATCH") })
        calls.removeAll()
        let broken = makeAccess { args in
            calls.append(args)
            return (0, "{}\n200")
        }
        XCTAssertFalse(broken.write(method: "DELETE", path: "/connections"))
        XCTAssertFalse(calls.contains { $0.contains("DELETE") })
    }

    func testReadsAndWritesReuseTheVerifiedEndpointWithinRound() throws {
        var calls: [[String]] = []
        let access = makeAccess { args in
            calls.append(args)
            if args.contains("DELETE") { return (0, "\n204") }
            if args.last?.hasSuffix("/connections") == true { return (0, "{\"connections\":[]}\n200") }
            return (0, self.config)
        }
        try ProbeContext.withValue(ProbeContext(timeout: 10)) {
            _ = try access.resolve().get()
            XCTAssertNotNil(access.read(path: "/connections"))
            #if !APP_STORE
            XCTAssertTrue(access.write(method: "DELETE", path: "/connections"))
            #endif
        }
        XCTAssertEqual(calls.filter { $0.last?.hasSuffix("/configs") == true }.count, 1)
        XCTAssertTrue(calls.allSatisfy { $0.contains(modern) })
    }

    private func settings(socket: String = "", controller: String = "http://127.0.0.1:9097/connections") -> MihomoControllerAccess.Settings {
        .init(socketPath: socket, controllerURL: controller, secret: "secret-value")
    }

    private func makeAccess(controller: String = "http://127.0.0.1:9097/connections",
                            run: @escaping MihomoControllerAccess.CommandRunner) -> MihomoControllerAccess {
        MihomoControllerAccess(settings: { self.settings(controller: controller) }, userID: 702, run: run)
    }
}
