import Foundation

enum IPVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case ipv4
    case ipv6

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "自动"
        case .ipv4:
            return "IPv4"
        case .ipv6:
            return "IPv6"
        }
    }
}

struct EgressIPInfo: Equatable, Sendable {
    let ip: String
    let ipVersion: IPVersion
    let locationRaw: String?
    let country: String?
    let province: String?
    let city: String?
    let asn: String?
    let asnName: String?
    let org: String?
    let isIDC: Bool?
    let ipRisk: Int?
    let isNative: Bool?
    let asnType: String?
    let orgType: String?
    let source: String
    let fetchedAt: Date

    var riskLabel: String {
        guard let ipRisk else { return "基础归属地" }
        return "纯净度: 风险值 \(ipRisk)"
    }

    var locationDisplay: String? {
        let structuredParts = [country, province, city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !structuredParts.isEmpty {
            return structuredParts.joined(separator: " / ")
        }

        let normalizedLocation = locationRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedLocation.isEmpty ? nil : normalizedLocation
    }

    var lastUpdatedText: String {
        let elapsed = Date().timeIntervalSince(fetchedAt)
        if elapsed < 60 { return "\(Int(elapsed))s 前" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m 前" }
        return "\(Int(elapsed / 3600))h 前"
    }
}

enum EgressIPError: LocalizedError, Equatable {
    case disabled
    case invalidEndpoint
    case httpStatus(Int)
    case invalidGeoResponse
    case invalidJSONResponse
    case timeout
    case networkUnavailable
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "出口 IP 检测已关闭"
        case .invalidEndpoint:
            return "IP 检测服务地址无效"
        case .httpStatus(let status):
            return "IP 检测服务返回 HTTP \(status)"
        case .invalidGeoResponse:
            return "ping0 基础信息响应格式不兼容"
        case .invalidJSONResponse:
            return "ping0 纯净度响应不是有效 JSON"
        case .timeout:
            return "出口 IP 检测超时"
        case .networkUnavailable:
            return "出口 IP 检测网络不可达"
        case .unknown(let message):
            return message
        }
    }
}

protocol IPIntelligenceClient {
    func lookupCurrentIP(version: IPVersion, apiKey: String?) async throws -> EgressIPInfo
    func lookup(ip: String, apiKey: String) async throws -> EgressIPInfo
}
