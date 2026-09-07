import Foundation

/// ping0.cc 结果页抽取数据的解析器（纯函数，无状态）。
///
/// 输入是 `Ping0WebClient` 注入页面的抽取脚本产出的 JSON 字符串，键名契约与
/// DOM 锚点快照见 skill spec：
/// skills/my/infra/local-dev-config/netbar-app-management/specs/001-ping0-ip-purity/contracts/ping0-dom-anchors.md
/// 字段级 best-effort：任何键缺失或格式异常时该字段为 nil，不整体失败；
/// 仅当连 IP 地址都取不到时才抛错。
enum Ping0PageParser {
    static func parse(extractionJSON: String, fetchedAt: Date = Date()) throws -> EgressIPInfo {
        guard let data = extractionJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ip = nonEmpty(json["ip"]) else {
            throw EgressIPError.invalidJSONResponse
        }

        let ipTypeText = nonEmpty(json["ipType"])
        let nativeText = nonEmpty(json["nativeText"])

        return EgressIPInfo(
            ip: ip,
            ipVersion: ip.contains(":") ? .ipv6 : .ipv4,
            locationRaw: nonEmpty(json["location"]),
            country: nil,
            province: nil,
            city: nil,
            asn: nonEmpty(json["asn"]),
            asnName: nonEmpty(json["asnName"]),
            org: nonEmpty(json["org"]),
            isIDC: ipTypeText.map { $0.contains("IDC") },
            ipRisk: intValue(nonEmpty(json["riskPercent"])),
            isNative: nativeText.map { $0.contains("原生") },
            asnType: nil,
            orgType: nil,
            ipTypeText: ipTypeText,
            sharedUsersText: nonEmpty(json["sharedUsers"]),
            aiDetectionText: nonEmpty(json["aiText"]),
            riskPercentText: nonEmpty(json["riskPercent"]),
            source: "ping0-web",
            fetchedAt: fetchedAt
        )
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "8%" → 8；容忍百分号与空白，解析不出返回 nil（该字段降级）。
    private static func intValue(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.filter { $0.isNumber }
        return Int(digits)
    }
}
