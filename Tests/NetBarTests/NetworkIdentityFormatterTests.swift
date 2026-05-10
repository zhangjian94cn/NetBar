import XCTest
@testable import NetBar

final class NetworkIdentityFormatterTests: XCTestCase {
    func testWifiTextShowsSSIDWhenPrivacyDisabled() {
        XCTAssertEqual(
            NetworkIdentityFormatter.wifiText(ssid: "OfficeWiFi", hideWiFiName: false),
            "Wi-Fi: OfficeWiFi"
        )
    }

    func testWifiTextHidesSSIDWhenPrivacyEnabled() {
        XCTAssertEqual(
            NetworkIdentityFormatter.wifiText(ssid: "OfficeWiFi", hideWiFiName: true),
            "Wi-Fi: 已隐藏"
        )
    }

    func testWifiTextHidesEmptyAndRedactedValues() {
        XCTAssertEqual(NetworkIdentityFormatter.wifiText(ssid: "", hideWiFiName: false), "Wi-Fi: 已隐藏")
        XCTAssertEqual(NetworkIdentityFormatter.wifiText(ssid: "  ", hideWiFiName: false), "Wi-Fi: 已隐藏")
        XCTAssertEqual(NetworkIdentityFormatter.wifiText(ssid: "—", hideWiFiName: false), "Wi-Fi: 已隐藏")
        XCTAssertEqual(NetworkIdentityFormatter.wifiText(ssid: "<redacted>", hideWiFiName: false), "Wi-Fi: 已隐藏")
    }

    func testLanTextLabelsLocalAddress() {
        XCTAssertEqual(NetworkIdentityFormatter.lanText(ip: "192.168.3.25"), "局域网: 192.168.3.25")
        XCTAssertEqual(NetworkIdentityFormatter.lanText(ip: ""), "局域网: —")
        XCTAssertEqual(NetworkIdentityFormatter.lanText(ip: "—"), "局域网: —")
    }
}
