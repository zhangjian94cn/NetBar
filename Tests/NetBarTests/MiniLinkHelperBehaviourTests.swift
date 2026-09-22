import XCTest

/// 以假二进制目录 + 沙箱 plist 实跑 Mini 端的 zsh helper，不触碰本机网络、不需要 root。
///
/// 2026-09-21 现场：当前 macOS 的 `networksetup -getinfo` 把没有的路由器打印成字面 `Router: (null)`，
/// helper 原样塞进 JSON 发给了 MacBook，卡片上就出现了「Mini (null)」。
final class MiniLinkHelperBehaviourTests: XCTestCase {
    private var sandbox: URL!
    private var binDir: URL!
    private var stateDir: URL!
    private var natProfile: URL!
    private var bootpdProfile: URL!
    private var guardianStatus: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbar-mini-helper-\(UUID().uuidString)", isDirectory: true)
        binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        stateDir = sandbox.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.sandbox) }

        try writePlist([
            "managementMiniAddress": "10.254.254.1",
            "managementLocalAddress": "10.254.254.2",
            "managementSubnetMask": "255.255.255.252",
            "miniUpstreamDevice": "en0",
        ], to: "profile.plist")
        natProfile = try writePlist([
            "NAT": [
                "Enabled": 1,
                "PrimaryInterface": ["Device": "en0"],
                "SharingDevices": ["en1", "bridge0"],
            ],
        ], to: "com.apple.nat.plist")
        bootpdProfile = try writePlist(["dhcp_enabled": false], to: "bootpd.plist")
        guardianStatus = sandbox.appendingPathComponent("status.json")
        try """
        {"state":"sharingManualPending","observedAt":"2026-09-21T09:58:18Z","generation":1,"sharingRunning":false,"forwardingEnabled":true}
        """.write(to: guardianStatus, atomically: true, encoding: .utf8)

        try fake("networksetup", body: """
        case "$1" in
          -listnetworkserviceorder)
            printf '(1) Ethernet\\n(Hardware Port: Ethernet, Device: en0)\\n\\n'
            printf '(2) Thunderbolt Bridge\\n(Hardware Port: Thunderbolt Bridge, Device: bridge0)\\n\\n' ;;
          -getinfo)
            printf 'DHCP Configuration\\nIP address: 169.254.56.135\\nSubnet mask: 255.255.0.0\\nRouter: (null)\\nClient ID: \\n' ;;
          -getdnsservers)
            printf "There aren't any DNS Servers set on Thunderbolt Bridge.\\n" ;;
        esac
        exit 0
        """)
        try fakeIfconfig(sharedAddress: "192.168.3.1")
        try fake("launchctl", body: "printf 'system/com.apple.NetworkSharing = {\\n\\tstate = not running\\n\\tprogram = /usr/libexec/InternetSharing\\n}\\n'; exit 0")
        try fake("sysctl", body: "printf '1\\n'; exit 0")
        try fake("netstat", body: "printf 'Routing tables\\n\\nInternet:\\nDestination Gateway Flags Netif Expire\\n'; exit 0")
        for name in ["system_profiler", "arp"] { try fake(name, body: "exit 0") }
    }

    func testStatusNeverEmitsTheLiteralNullAndFallsBackToTheSharedAddress() throws {
        let result = run(["status"])

        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertFalse(result.out.contains("(null)"), result.out)
        let json = try decode(result.out)
        XCTAssertEqual(json["protocolVersion"] as? Int, 5)
        XCTAssertEqual(json["serviceIPv4"] as? String, "192.168.3.1")
        XCTAssertEqual(json["gatewayIPv4"] as? String, "192.168.3.1", "没有路由器时退回共享地址，而不是把 (null) 当地址")
        XCTAssertEqual(json["configured"] as? Bool, true)
        XCTAssertEqual(json["sharingIntentEnabled"] as? Bool, true)
        XCTAssertEqual(json["dhcpServerEnabled"] as? Bool, false)
        XCTAssertEqual(json["sharingProcessRunning"] as? Bool, false)
        XCTAssertEqual(json["forwardingEnabled"] as? Bool, true)
        XCTAssertEqual(json["evidenceConflict"] as? Bool, false)
        XCTAssertEqual((json["guardian"] as? [String: Any])?["state"] as? String, "sharingManualPending")
    }

    func testStatusReportsNullAddressesWhenBridgeOnlyHasManagementAndLinkLocal() throws {
        try fakeIfconfig(sharedAddress: nil)

        let result = run(["status"])

        XCTAssertEqual(result.status, 0, result.err)
        let json = try decode(result.out)
        XCTAssertTrue(json["serviceIPv4"] is NSNull, result.out)
        XCTAssertTrue(json["gatewayIPv4"] is NSNull, result.out)
        XCTAssertFalse(result.out.contains("(null)"))
    }

    func testGuardianClaimThatDisagreesWithLiveFactsIsFlaggedAsConflict() throws {
        try """
        {"state":"ready","observedAt":"2026-09-21T09:58:18Z","generation":1,"sharingRunning":true,"forwardingEnabled":true}
        """.write(to: guardianStatus, atomically: true, encoding: .utf8)

        let json = try decode(run(["status"]).out)

        XCTAssertEqual(json["evidenceConflict"] as? Bool, true, "status.json 说进程在跑，launchctl 说没有")
    }

    func testDownstreamEgressReportIsNoLongerACommand() {
        XCTAssertNotEqual(run(["report-egress-failure"]).status, 0)
    }

    // 备份是回滚的输入：把 "(null)" 存成路由器，回滚就会把它喂给 -setmanual。
    func testPrepareBackupStoresAnEmptyRouterInsteadOfNull() throws {
        let result = run(["prepare"])

        XCTAssertEqual(result.status, 0, result.err)
        let backup = stateDir.appendingPathComponent("mini-network-backup-v5.plist")
        let data = try Data(contentsOf: backup)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["method"] as? String, "DHCP")
        XCTAssertEqual(plist["router"] as? String, "")
        XCTAssertEqual(plist["ip"] as? String, "169.254.56.135")
    }

    // MARK: - Harness

    @discardableResult
    private func writePlist(_ object: [String: Any], to name: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
        return url
    }

    private func fake(_ name: String, body: String) throws {
        let url = binDir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func fakeIfconfig(sharedAddress: String?) throws {
        let shared = sharedAddress.map { "\\tinet \($0) netmask 0xffffff00 broadcast 192.168.3.255\\n" } ?? ""
        try fake("ifconfig", body: """
        case "$1" in
          en0) printf 'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\\n\\tinet 10.32.143.206 netmask 0xffffff00\\n\\tstatus: active\\n' ;;
          *)
            printf 'bridge0: flags=8a63<UP,BROADCAST,SMART,RUNNING,ALLMULTI,SIMPLEX,MULTICAST> mtu 1500\\n'
            printf '\(shared)'
            printf '\\tinet 10.254.254.1 netmask 0xfffffffc broadcast 10.254.254.3\\n'
            printf '\\tinet 169.254.56.135 netmask 0xffff0000 broadcast 169.254.255.255\\n'
            printf '\\tmember: en2 flags=3<LEARNING,DISCOVER>\\n\\tstatus: active\\n' ;;
        esac
        exit 0
        """)
    }

    private var helperPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NetBar/Resources/MiniLinkHelper/netbar-mini-link-helper")
            .path
    }

    private func run(_ args: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperPath] + args
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PROFILE": sandbox.appendingPathComponent("profile.plist").path,
            "NAT_PROFILE": natProfile.path,
            "BOOTPD_PROFILE": bootpdProfile.path,
            "GUARDIAN_STATUS": guardianStatus.path,
            "STATE_DIR": stateDir.path,
        ]
        for name in ["networksetup", "ifconfig", "launchctl", "sysctl", "netstat", "system_profiler", "arp"] {
            env[name.uppercased()] = binDir.appendingPathComponent(name).path
        }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    private func decode(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
            "helper 输出不是 JSON 对象: \(output)"
        )
    }
}
