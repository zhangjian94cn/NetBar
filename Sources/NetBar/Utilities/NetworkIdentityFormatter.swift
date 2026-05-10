import Foundation

enum NetworkIdentityFormatter {
    static func wifiText(ssid: String, hideWiFiName: Bool) -> String {
        guard !hideWiFiName else {
            return "Wi-Fi: 已隐藏"
        }

        let normalizedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSSID.isEmpty,
              normalizedSSID != "—",
              normalizedSSID.lowercased() != "<redacted>" else {
            return "Wi-Fi: 已隐藏"
        }

        return "Wi-Fi: \(normalizedSSID)"
    }

    static func lanText(ip: String) -> String {
        let normalizedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIP.isEmpty, normalizedIP != "—" else {
            return "局域网: —"
        }
        return "局域网: \(normalizedIP)"
    }
}
