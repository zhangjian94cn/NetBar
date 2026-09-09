import XCTest

/// 两个特权 helper 合计 14 个 action、约 50 条 fail 分支，此前**行为覆盖为零**——
/// 唯一被真正执行过的只有参数校验，其余全靠对源码做字符串 grep，那既证明不了运行时行为，
/// 也会被重命名或空格改动打破。
///
/// 阻塞点原本是脚本把外部二进制与状态路径无条件硬编码，测试既装不了假 networksetup，
/// 也重定向不了 /Library/Application Support。改成可覆盖默认值后，这里用假 bin 目录 +
/// 临时状态目录跑真实脚本，不触碰本机网络、不需要 root。
final class RouteSafetyHelperBehaviourTests: XCTestCase {
    private var sandbox: URL!
    private var binDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-helper-\(UUID().uuidString)", isDirectory: true)
        binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        stateDir = sandbox.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.sandbox) }

        try fake("networksetup", body: """
        if [ "$1" = "-listnetworkserviceorder" ]; then
          printf 'An asterisk (*) denotes that a network service is disabled.\\n'
          printf '(1) Wi-Fi\\n(Hardware Port: Wi-Fi, Device: en0)\\n\\n'
          printf '(2) Thunderbolt Bridge\\n(Hardware Port: Thunderbolt Bridge, Device: bridge0)\\n\\n'
        elif [ "$1" = "-getdnsservers" ]; then
          printf '1.1.1.1\\n'
        fi
        exit 0
        """)
        for name in ["ifconfig", "route", "netstat", "plutil", "shasum"] {
            try fake(name, body: "exit 0")
        }
    }

    private func fake(_ name: String, body: String) throws {
        let url = binDir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private var helperPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NetBar/Resources/RouteSafetyHelper/netbar-route-safety-helper")
            .path
    }

    @discardableResult
    private func run(_ args: [String], extraEnv: [String: String] = [:]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperPath] + args
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "STATE_DIR": stateDir.path,
            "PROFILE": sandbox.appendingPathComponent("profile.plist").path,
        ]
        for name in ["networksetup", "ifconfig", "route", "netstat", "plutil", "shasum"] {
            env[name.uppercased()] = binDir.appendingPathComponent(name).path
        }
        env.merge(extraEnv) { _, new in new }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: o, as: UTF8.self),
                String(decoding: e, as: UTF8.self))
    }

    func testStatusEmitsProtocolFiveFactsWithoutTouchingTheRealSystem() throws {
        let result = run(["status"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("\"protocolVersion\":5"), result.out)
        XCTAssertTrue(result.out.contains("\"wifiDevice\":\"en0\""), result.out)
        XCTAssertTrue(result.out.contains("\"miniService\":\"Thunderbolt Bridge\""), result.out)
        XCTAssertTrue(result.out.contains("\"pendingTransaction\":false"), result.out)
    }

    func testMissingRequiredServiceFailsClosedBeforeAnyWrite() throws {
        try fake("networksetup", body: "printf 'An asterisk (*) denotes that a network service is disabled.\\n'; exit 0")
        let result = run(["status"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.err.contains("not found"), result.err)
    }

    func testCommitWithoutAPendingTransactionIsRefused() throws {
        let result = run(["commit"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.err.contains("pending"), result.err)
    }

    func testRollbackWithoutABackupIsRefused() throws {
        let result = run(["rollback"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.err.contains("pending"), result.err)
    }

    func testUnknownCommandAndWrongArityAreRejected() {
        XCTAssertNotEqual(run(["definitely-not-a-command"]).status, 0)
        XCTAssertNotEqual(run([]).status, 0)
        XCTAssertNotEqual(run(["status", "extra"]).status, 0)
    }

    // status 必须保持无锁：特权写超时后 root 子进程仍持锁，此时若 status 也被锁住，
    // 上层就无法核对未决事务，只能把「helper 忙」误判成「helper 未安装」。
    func testStatusStaysReadableWhileTheWriteLockIsHeld() throws {
        let lock = stateDir.appendingPathComponent("execution.lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/zsh")
        holder.arguments = ["-c", "zmodload zsh/system; zsystem flock -f FD \(lock.path); sleep 3"]
        try holder.run()
        defer { holder.terminate() }
        Thread.sleep(forTimeInterval: 0.4)

        let readOnly = run(["status"])
        XCTAssertEqual(readOnly.status, 0, "写锁被占用时 status 仍必须可读：\(readOnly.err)")

        let write = run(["prefer-wifi"])
        XCTAssertNotEqual(write.status, 0)
        XCTAssertTrue(write.err.contains("busy"), "写动作应快速失败并说明忙碌：\(write.err)")
    }
}
