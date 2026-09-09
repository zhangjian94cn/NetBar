import XCTest
@testable import NetBar

// App Store Lite 的 stub 分支此前完全没有测试：`swift test` 只跑默认 flavor，
// 这些 `#if APP_STORE` 代码在任何构建下都无人验证。它们承担的是安全职责——
// 该版本不得声称拥有它没有的能力，也不得试图走特权路径。
#if APP_STORE
final class AppStoreLiteFlavorTests: XCTestCase {
    func testFlavorIsAppStoreLiteAndRefusesNetworkModeSwitch() {
        XCTAssertEqual(DistributionFlavor.current, .appStoreLite)
        XCTAssertFalse(DistributionFlavor.current.supportsNetworkModeSwitch)
    }

    func testRouteSafetyControllerReportsNoHelperAndFailsEveryWrite() {
        let controller = LiveRouteSafetyController()
        XCTAssertNil(controller.status(), "没有 helper 就必须报告没有，而不是返回一个假的就绪状态")
        XCTAssertFalse(controller.apply(.macMiniGateway).succeeded)
        XCTAssertFalse(controller.apply(.localWiFi).succeeded)
        XCTAssertFalse(controller.repairWiFiDNS().succeeded)
    }

    func testLinkProvisionerRefusesInsteadOfPretendingToSucceed() {
        XCTAssertEqual(NetworkLinkProvisioner().provision().kind, .failed)
    }

    func testPopoverExposesOnlyMonitoringSection() {
        XCTAssertEqual(PopoverSection.available(for: .appStoreLite), [.monitoring])
        XCTAssertEqual(PopoverSection.resolve(storedValue: "outlet", flavor: .appStoreLite), .monitoring)
    }
}
#endif
