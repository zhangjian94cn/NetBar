import XCTest
@testable import NetBar

final class LaunchAgentManagerTests: XCTestCase {
    func testPlistXMLUsesLaunchAgentContract() {
        let xml = LaunchAgentManager.plistXML(programPath: "/tmp/NetBar & Test")

        XCTAssertTrue(xml.contains("<string>com.netbar.agent</string>"))
        XCTAssertTrue(xml.contains("<string>/tmp/NetBar &amp; Test</string>"))
        XCTAssertTrue(xml.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(xml.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(xml.contains("<string>/tmp/netbar.log</string>"))
        XCTAssertTrue(xml.contains("<string>/tmp/netbar.err</string>"))
    }
}
