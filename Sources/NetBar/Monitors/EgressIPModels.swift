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

/// ping0 官方风控六档（边界口径见 https://ping0.cc/ip/faq，区间左闭右开：
/// 15 归「纯净」档，与页面 title "0-15 极度纯净 / 15-25 纯净" 一致）。
enum RiskTier: Equatable, Sendable, CaseIterable {
    case extremelyPure
    case pure
    case neutral
    case slightRisk
    case moderateRisk
    case extremeRisk

    init?(risk: Int) {
        switch risk {
        case ..<15: self = .extremelyPure
        case 15..<25: self = .pure
        case 25..<40: self = .neutral
        case 40..<50: self = .slightRisk
        case 50..<70: self = .moderateRisk
        default: self = .extremeRisk
        }
    }

    var displayName: String {
        switch self {
        case .extremelyPure: return "极度纯净"
        case .pure: return "纯净"
        case .neutral: return "中性"
        case .slightRisk: return "轻微风险"
        case .moderateRisk: return "稍高风险"
        case .extremeRisk: return "极度风险"
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
    /// 网页链路的「IP 类型」原文（如 "家庭宽带 IP" / "IDC机房IP"）；付费接口链路为 nil。
    var ipTypeText: String? = nil
    /// 网页链路的「共享人数」区间原文（如 "1 - 10 (极好)"）；中国大陆 IP 该行缺失，为 nil。
    var sharedUsersText: String? = nil
    /// 网页链路的「大模型检测」结论原文（如 "家庭宽带的概率为 52%"）；未出结论为 nil。
    var aiDetectionText: String? = nil
    /// 网页链路的风控值原始百分比展示（如 "8%"）；付费接口链路为 nil。
    var riskPercentText: String? = nil
    let source: String
    let fetchedAt: Date

    var riskTier: RiskTier? {
        ipRisk.flatMap { RiskTier(risk: $0) }
    }

    var riskLabel: String {
        guard let ipRisk else { return "基础归属地" }
        let value = riskPercentText ?? "\(ipRisk)"
        guard let riskTier else { return "风控值 \(value)" }
        return "风控值 \(value) · \(riskTier.displayName)"
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
    case webpageNotReady
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
        case .webpageNotReady:
            return "ping0 页面未就绪（可能触发了人工验证，稍后重试）"
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
