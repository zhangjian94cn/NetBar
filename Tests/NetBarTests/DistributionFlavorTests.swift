import XCTest
@testable import NetBar

final class DistributionFlavorTests: XCTestCase {
    func testCurrentFlavorMatchesBuildFlag() {
        #if APP_STORE
        XCTAssertEqual(DistributionFlavor.current, .appStoreLite)
        XCTAssertFalse(DistributionFlavor.current.supportsProcessTraffic)
        XCTAssertFalse(DistributionFlavor.current.usesLaunchAgentStartup)
        XCTAssertFalse(DistributionFlavor.current.supportsNetworkModeSwitch)
        XCTAssertFalse(DistributionFlavor.current.supportsClashModeSwitch)
        #else
        XCTAssertEqual(DistributionFlavor.current, .directFull)
        XCTAssertTrue(DistributionFlavor.current.supportsProcessTraffic)
        XCTAssertTrue(DistributionFlavor.current.usesLaunchAgentStartup)
        XCTAssertTrue(DistributionFlavor.current.supportsNetworkModeSwitch)
        XCTAssertTrue(DistributionFlavor.current.supportsClashModeSwitch)
        #endif
    }
}
