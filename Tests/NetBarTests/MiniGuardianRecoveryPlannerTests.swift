import XCTest
import NetBarMiniNetworkGuardianSupport

/// 2026-09-21：Mini 的上游 HTTPS 探测失败一次，旧规划器 15 秒后判定「重启共享」，杀掉 Apple 的
/// InternetSharing 再拉起，共享从此永久停止。这里的每一条测试都在守同一条线：规划器只产出状态，
/// 任何事实、任何时长都换不出一个对 Apple 进程的动作。
final class MiniGuardianRecoveryPlannerTests: XCTestCase {
    private typealias Planner = MiniGuardianRecoveryPlanner

    func testAppleDHCPRequiresBridgeZeroInCurrentInterfaceListEncoding() {
        XCTAssertTrue(Planner.appleDHCPEnabled(from: ["bridge100", "bridge0"]))
        XCTAssertFalse(Planner.appleDHCPEnabled(from: ["bridge100", "en1"]))
        XCTAssertTrue(Planner.appleDHCPEnabled(from: true))
        XCTAssertTrue(Planner.appleDHCPEnabled(from: NSNumber(value: 1)))
        XCTAssertFalse(Planner.appleDHCPEnabled(from: NSNumber(value: 2)))
    }

    func testAppleDHCPFallsBackToDisabledForMissingOrUnexpectedEncodings() {
        XCTAssertFalse(Planner.appleDHCPEnabled(from: nil))
        XCTAssertFalse(Planner.appleDHCPEnabled(from: "bridge0"))
        XCTAssertFalse(Planner.appleDHCPEnabled(from: Date()))
    }

    // MARK: US1 观察不干预

    /// 穷举 switch：一旦有人给决策集合加回任何「动作」，这里先编译失败。
    private func isPureState(_ decision: MiniGuardianRecoveryDecision) -> Bool {
        switch decision {
        case .carrierDown, .configurationDrift, .managementLinkRecovering, .addressRecovering,
             .sharingRecovering, .sharingManualPending, .upstreamUnreachable, .readyStabilizing, .ready:
            return true
        }
    }

    func testEveryVerdictIsAStateNeverAnAction() {
        let inputs: [(MiniGuardianServingFacts, TimeInterval?, TimeInterval?)] = [
            (facts(), nil, nil),
            (facts(sharingRunning: false), 9_000, nil),
            (facts(dhcpServerEnabled: false), 9_000, nil),
            (facts(forwardingEnabled: false), 9_000, nil),
            (facts(upstreamReachable: false), 9_000, nil),
            (facts(carrierActive: false), 9_000, nil),
            (facts(managementAddressReady: false, managementAliasRestorable: false), 9_000, nil),
        ]
        for (input, waited, healthy) in inputs {
            XCTAssertTrue(isPureState(Planner.decide(input, sharingWaitElapsed: waited, healthyElapsed: healthy)))
        }
    }

    // 事故根因：上游探测失败被归入「共享未就绪」，15 秒后接到了重启路径上。
    func testUpstreamProbeFailureIsItsOwnStateForAnyDurationAndNeverBecomesManualPending() {
        for waited: TimeInterval? in [nil, 0, 15, 89, 90, 3_600] {
            XCTAssertEqual(
                Planner.decide(facts(upstreamReachable: false), sharingWaitElapsed: waited, healthyElapsed: 600),
                .upstreamUnreachable,
                "waited=\(String(describing: waited))"
            )
        }
    }

    func testHotspotStateIsNotAServingFact() {
        // 热点 AP 不在输入里：编译期就保证它无法影响判定。这里只固定一个语义——只剩雷雳事实时就能 ready。
        XCTAssertEqual(Planner.decide(facts(), sharingWaitElapsed: nil, healthyElapsed: 60), .ready)
    }

    func testCarrierDownOnlyWaitsForCarrier() {
        XCTAssertEqual(Planner.decide(facts(carrierActive: false), sharingWaitElapsed: 9_000, healthyElapsed: nil), .carrierDown)
    }

    func testManagementAliasIsVerifiedWhenRestorableAndReportedAsDriftWhenNot() {
        XCTAssertEqual(
            Planner.decide(facts(managementAddressReady: false), sharingWaitElapsed: nil, healthyElapsed: nil),
            .managementLinkRecovering
        )
        XCTAssertEqual(
            Planner.decide(
                facts(managementAddressReady: false, managementAliasRestorable: false),
                sharingWaitElapsed: nil,
                healthyElapsed: nil
            ),
            .configurationDrift("management subnet conflicts or bridge identity unavailable")
        )
    }

    // 父 Spec FR-007：管理面独立于上游与共享——共享关着、载波掉了，别名照样要修。
    func testManagementRecoveryDoesNotDependOnUpstreamOrSharing() {
        for input in [
            facts(carrierActive: false, managementAddressReady: false),
            facts(sharingConfigured: false, managementAddressReady: false),
            facts(sharingIntentEnabled: false, managementAddressReady: false),
            facts(dhcpServerEnabled: false, managementAddressReady: false),
            facts(managementAddressReady: false, upstreamReachable: false),
        ] {
            XCTAssertEqual(Planner.decide(input, sharingWaitElapsed: nil, healthyElapsed: nil), .managementLinkRecovering)
        }
    }

    func testConfigurationDriftRefusesToGuess() {
        XCTAssertEqual(
            Planner.decide(facts(bridgeUsesDHCP: false), sharingWaitElapsed: nil, healthyElapsed: nil),
            .configurationDrift("Thunderbolt Bridge must use DHCP; fixed IPv4 conflicts with Internet Sharing")
        )
        XCTAssertEqual(
            Planner.decide(facts(preferencesMatch: false, addressReady: false), sharingWaitElapsed: nil, healthyElapsed: nil),
            .configurationDrift("en0 manual configuration differs from NetBar profile")
        )
        XCTAssertEqual(
            Planner.decide(facts(sharingConfigured: false, sharingRunning: false), sharingWaitElapsed: nil, healthyElapsed: nil),
            .configurationDrift("Internet Sharing must use en0 and include Wi-Fi plus bridge0")
        )
    }

    func testAddressRecoveryIsIndefiniteAndNeverEscalates() {
        XCTAssertEqual(Planner.decide(facts(addressReady: false), sharingWaitElapsed: nil, healthyElapsed: nil), .addressRecovering)
        XCTAssertEqual(Planner.decide(facts(routeReady: false), sharingWaitElapsed: 9_000, healthyElapsed: nil), .addressRecovering)
    }

    // MARK: US2 状态如实与原因

    func testSharingSwitchedOffIsManualPendingImmediately() {
        XCTAssertEqual(
            Planner.decide(facts(sharingIntentEnabled: false, sharingRunning: false), sharingWaitElapsed: nil, healthyElapsed: nil),
            .sharingManualPending("enable Internet Sharing in System Settings")
        )
    }

    // 2026-09-14：Apple 重建共享的 20 秒里 dhcp_enabled 短暂为 0，旧规划器把它报成需人工。
    func testTransientNotServingIsRecoveringUntilTheGracePeriodThenManualPendingWithReason() {
        let dhcpOff = facts(dhcpServerEnabled: false)
        XCTAssertEqual(
            Planner.decide(dhcpOff, sharingWaitElapsed: nil, healthyElapsed: nil),
            .sharingRecovering(reason: "Apple DHCP is disabled", remaining: 90)
        )
        XCTAssertEqual(
            Planner.decide(dhcpOff, sharingWaitElapsed: 89, healthyElapsed: nil),
            .sharingRecovering(reason: "Apple DHCP is disabled", remaining: 1)
        )
        XCTAssertEqual(
            Planner.decide(dhcpOff, sharingWaitElapsed: 90, healthyElapsed: nil),
            .sharingManualPending("Apple DHCP is disabled; toggle Internet Sharing off and on in System Settings")
        )
        XCTAssertEqual(Planner.sharingRecoveryGracePeriod, 90)
    }

    func testEveryNotServingFactIsNamedInTheReason() {
        XCTAssertEqual(Planner.notServingFacts(facts(sharingRunning: false)), ["InternetSharing is not running"])
        XCTAssertEqual(Planner.notServingFacts(facts(forwardingEnabled: false)), ["kernel forwarding is disabled"])
        XCTAssertEqual(Planner.notServingFacts(facts(sharedAddressReady: false)), ["no shared IPv4 on bridge0"])
        XCTAssertEqual(
            Planner.decide(
                facts(dhcpServerEnabled: false, sharedAddressReady: false, sharingRunning: false, forwardingEnabled: false),
                sharingWaitElapsed: 120,
                healthyElapsed: nil
            ),
            .sharingManualPending(
                "Apple DHCP is disabled; InternetSharing is not running; kernel forwarding is disabled; " +
                "no shared IPv4 on bridge0; toggle Internet Sharing off and on in System Settings"
            )
        )
    }

    func testHealthyStateStabilizesForThirtySeconds() {
        XCTAssertEqual(Planner.decide(facts(), sharingWaitElapsed: nil, healthyElapsed: nil), .readyStabilizing(30))
        XCTAssertEqual(Planner.decide(facts(), sharingWaitElapsed: nil, healthyElapsed: 0), .readyStabilizing(30))
        XCTAssertEqual(Planner.decide(facts(), sharingWaitElapsed: nil, healthyElapsed: 29), .readyStabilizing(1))
        XCTAssertEqual(Planner.decide(facts(), sharingWaitElapsed: nil, healthyElapsed: 30), .ready)
        XCTAssertEqual(Planner.decide(facts(), sharingWaitElapsed: nil, healthyElapsed: 600), .ready)
    }

    // healthySince 由 Guardian 用 isFullyHealthy 独立求值再回喂 planner；两处定义若不同，
    // 「Mini 何时算稳定」会静默偏移。这里把它们钉在一起：健康 ⇔ decide 走到稳定/ready 分支。
    func testHealthDefinitionIsExactlyTheReadyPrecondition() {
        XCTAssertTrue(Planner.isFullyHealthy(facts()))
        XCTAssertEqual(Planner.decide(facts(), sharingWaitElapsed: nil, healthyElapsed: 60), .ready)

        let singleFaults: [(String, MiniGuardianServingFacts)] = [
            ("carrierActive", facts(carrierActive: false)),
            ("preferencesMatch", facts(preferencesMatch: false)),
            ("sharingConfigured", facts(sharingConfigured: false)),
            ("sharingIntentEnabled", facts(sharingIntentEnabled: false)),
            ("dhcpServerEnabled", facts(dhcpServerEnabled: false)),
            ("managementAddressReady", facts(managementAddressReady: false)),
            ("bridgeUsesDHCP", facts(bridgeUsesDHCP: false)),
            ("sharedAddressReady", facts(sharedAddressReady: false)),
            ("addressReady", facts(addressReady: false)),
            ("routeReady", facts(routeReady: false)),
            ("sharingRunning", facts(sharingRunning: false)),
            ("forwardingEnabled", facts(forwardingEnabled: false)),
            ("upstreamReachable", facts(upstreamReachable: false)),
        ]
        for (name, input) in singleFaults {
            XCTAssertFalse(Planner.isFullyHealthy(input), "\(name) 为假时不应判定为完全健康")
            let decision = Planner.decide(input, sharingWaitElapsed: nil, healthyElapsed: 600)
            XCTAssertNotEqual(decision, .ready, "\(name) 为假时不得 ready")
            if case .readyStabilizing = decision { XCTFail("\(name) 为假时不得进入稳定窗口") }
        }
    }

    func testServiceParserDoesNotTreatHardwarePortLineAsServiceTitle() {
        let output = """
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en1)
        (2) *Ethernet Company Manual
        (Hardware Port: Ethernet, Device: en0)
        (3) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        """

        XCTAssertEqual(NetworkServiceOrderParser.serviceName(forDevice: "en0", in: output), "Ethernet Company Manual")
        XCTAssertEqual(NetworkServiceOrderParser.serviceName(forDevice: "bridge0", in: output), "Thunderbolt Bridge")
    }

    private func facts(
        carrierActive: Bool = true,
        preferencesMatch: Bool = true,
        sharingConfigured: Bool = true,
        sharingIntentEnabled: Bool = true,
        dhcpServerEnabled: Bool = true,
        managementAddressReady: Bool = true,
        managementAliasRestorable: Bool = true,
        bridgeUsesDHCP: Bool = true,
        sharedAddressReady: Bool = true,
        addressReady: Bool = true,
        routeReady: Bool = true,
        sharingRunning: Bool = true,
        forwardingEnabled: Bool = true,
        upstreamReachable: Bool = true
    ) -> MiniGuardianServingFacts {
        MiniGuardianServingFacts(
            carrierActive: carrierActive,
            preferencesMatch: preferencesMatch,
            sharingConfigured: sharingConfigured,
            sharingIntentEnabled: sharingIntentEnabled,
            dhcpServerEnabled: dhcpServerEnabled,
            managementAddressReady: managementAddressReady,
            managementAliasRestorable: managementAliasRestorable,
            bridgeUsesDHCP: bridgeUsesDHCP,
            sharedAddressReady: sharedAddressReady,
            addressReady: addressReady,
            routeReady: routeReady,
            sharingRunning: sharingRunning,
            forwardingEnabled: forwardingEnabled,
            upstreamReachable: upstreamReachable
        )
    }
}

final class GuardianInterfaceFactsTests: XCTestCase {
    private let bridgeWithMember = """
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tinet 10.32.143.206 netmask 0xffffff00 broadcast 10.32.143.255
    bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tConfiguration:
    \tmember: en2 flags=3<LEARNING,DISCOVER>
    \tinet 192.168.3.1 netmask 0xffffff00 broadcast 192.168.3.255
    """

    func testAliasIsRestorableOnlyWhenBridgeIdentityIsKnown() {
        XCTAssertTrue(GuardianInterfaceFacts.managementAliasCanBeRestored(
            ifconfigOutput: bridgeWithMember, managementSubnetPrefix: "10.254.254."
        ))

        // 同名但没有 member 的空桥：不能把管理别名写上去。
        let memberless = bridgeWithMember.replacingOccurrences(of: "member: en2", with: "ipfilter disabled")
        XCTAssertFalse(GuardianInterfaceFacts.managementAliasCanBeRestored(
            ifconfigOutput: memberless, managementSubnetPrefix: "10.254.254."
        ))
    }

    func testManagementSubnetAppearingElsewhereBlocksTheRepair() {
        let conflicting = bridgeWithMember + "\nutun9: flags=8051<UP,POINTOPOINT,RUNNING> mtu 1380\n\tinet 10.254.254.9 --> 10.254.254.9 netmask 0xfffffffc"
        XCTAssertFalse(
            GuardianInterfaceFacts.managementAliasCanBeRestored(
                ifconfigOutput: conflicting, managementSubnetPrefix: "10.254.254."
            ),
            "管理网段已出现在别的接口上，写别名会造成地址冲突"
        )
    }

    func testBridgeOwnManagementAddressIsNotTreatedAsAConflict() {
        let alreadyAliased = bridgeWithMember + "\n\tinet 10.254.254.1 netmask 0xfffffffc broadcast 10.254.254.3"
        XCTAssertTrue(GuardianInterfaceFacts.managementAliasCanBeRestored(
            ifconfigOutput: alreadyAliased, managementSubnetPrefix: "10.254.254."
        ))
    }

    // 原实现把网段写死成 "10.254.254."，profile 换网段时这道保护会静默失效。
    func testSubnetPrefixFollowsTheProfileInsteadOfAHardcodedValue() {
        XCTAssertEqual(GuardianInterfaceFacts.managementSubnetPrefix(forAddress: "10.254.254.1"), "10.254.254.")
        XCTAssertEqual(GuardianInterfaceFacts.managementSubnetPrefix(forAddress: "172.31.9.1"), "172.31.9.")
        XCTAssertEqual(GuardianInterfaceFacts.managementSubnetPrefix(forAddress: "garbage"), "garbage")

        let otherSubnet = bridgeWithMember + "\nutun9: flags=8051<UP> mtu 1380\n\tinet 172.31.9.9 netmask 0xfffffffc"
        XCTAssertFalse(GuardianInterfaceFacts.managementAliasCanBeRestored(
            ifconfigOutput: otherSubnet, managementSubnetPrefix: "172.31.9."
        ))
        XCTAssertTrue(GuardianInterfaceFacts.managementAliasCanBeRestored(
            ifconfigOutput: otherSubnet, managementSubnetPrefix: "10.254.254."
        ))
    }

    func testSharingIntentAcceptsBothBoolAndIntEncodings() {
        XCTAssertTrue(GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: ["NAT": ["Enabled": true]]))
        XCTAssertTrue(GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: ["NAT": ["Enabled": 1]]))
        XCTAssertFalse(GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: ["NAT": ["Enabled": false]]))
        XCTAssertFalse(GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: ["NAT": ["Enabled": 0]]))
    }

    func testSharingIntentFailsClosedOnMissingOrMalformedPlist() {
        XCTAssertFalse(GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: nil))
        XCTAssertFalse(GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: [:]))
        XCTAssertFalse(GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: ["NAT": "not a dictionary"]))
        XCTAssertFalse(
            GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: ["NAT": ["Enabled": "yes"]]),
            "字符串编码不被接受，宁可判为未开启也不猜"
        )
    }
}
