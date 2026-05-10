import XCTest
@testable import NetBar

final class TunnelRouteDetectorTests: XCTestCase {
    func testBroadTunnelRoutesAreActive() {
        let routes = [
            TunnelRouteDetector.IPv4Route(destination: "1", interface: "utun5"),
            TunnelRouteDetector.IPv4Route(destination: "2/7", interface: "utun5")
        ]

        let interfaces = TunnelRouteDetector.activeTunnelInterfaces(
            in: routes,
            activeInterfaces: ["utun5"]
        )

        XCTAssertEqual(interfaces, ["utun5"])
    }

    func testNarrowUtunRouteIsNotActiveTunnel() {
        let routes = [
            TunnelRouteDetector.IPv4Route(destination: "10.8/24", interface: "utun9")
        ]

        let interfaces = TunnelRouteDetector.activeTunnelInterfaces(
            in: routes,
            activeInterfaces: ["utun9"]
        )

        XCTAssertTrue(interfaces.isEmpty)
    }

    func testInactiveTunnelInterfaceIsIgnored() {
        let routes = [
            TunnelRouteDetector.IPv4Route(destination: "1", interface: "utun5")
        ]

        let interfaces = TunnelRouteDetector.activeTunnelInterfaces(
            in: routes,
            activeInterfaces: ["utun9"]
        )

        XCTAssertTrue(interfaces.isEmpty)
    }

    func testParsesNetstatRoutes() {
        let output = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.3.1        UGScg                 en0
        1                  10.0.0.1           UGSc                utun5
        10.8/24            10.0.0.1           UGSc                utun9
        """

        let routes = TunnelRouteDetector.parseIPv4Routes(output)

        XCTAssertEqual(routes, [
            TunnelRouteDetector.IPv4Route(destination: "1", interface: "utun5"),
            TunnelRouteDetector.IPv4Route(destination: "10.8/24", interface: "utun9")
        ])
    }
}
