import Foundation

struct ParsedVPSPanelURL: Equatable {
    let useTLS: Bool
    let host: String
    let port: Int
    let basePath: String
}

enum VPSConnectionError: LocalizedError, Equatable {
    case invalidURL(String)
    case missingHost
    case unsupportedScheme(String)
    case invalidPort
    case networkUnavailable
    case timeout
    case tlsCertificateFailed
    case httpStatus(Int)
    case pathNotFound
    case invalidCredentials(String?)
    case invalidResponse
    case inboundsAPIIncompatible
    case missingCookie
    case passwordRequired
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "面板地址格式不正确：\(value)"
        case .missingHost:
            return "面板地址缺少主机名"
        case .unsupportedScheme(let scheme):
            return "暂不支持 \(scheme) 地址，请使用 http 或 https"
        case .invalidPort:
            return "端口必须是 1 到 65535 之间的数字"
        case .networkUnavailable:
            return "网络不可达，请检查地址或网络连接"
        case .timeout:
            return "连接超时，请检查地址、端口或防火墙"
        case .tlsCertificateFailed:
            return "TLS 证书校验失败。如确认是自签证书，请开启“允许自签证书”"
        case .httpStatus(let status):
            return "服务器返回 HTTP \(status)"
        case .pathNotFound:
            return "面板路径错误或 API 不兼容"
        case .invalidCredentials(let message):
            if let message, !message.isEmpty {
                return "用户名或密码错误：\(message)"
            }
            return "用户名或密码错误"
        case .invalidResponse:
            return "面板响应不是有效的 3X-UI JSON"
        case .inboundsAPIIncompatible:
            return "inbounds API 不兼容，请确认这是 3X-UI 面板"
        case .missingCookie:
            return "登录成功但未返回会话 Cookie"
        case .passwordRequired:
            return "请先输入密码并测试连接"
        case .unknown(let message):
            return message
        }
    }
}

struct ConnectionTestResult: Equatable {
    let success: Bool
    let message: String

    static let success = ConnectionTestResult(success: true, message: "连接成功")

    static func failure(_ error: Error) -> ConnectionTestResult {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return ConnectionTestResult(success: false, message: message)
    }
}

enum VPSPanelURLParser {
    static func parse(_ rawValue: String) throws -> ParsedVPSPanelURL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VPSConnectionError.invalidURL(rawValue)
        }

        let urlValue = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: urlValue) else {
            throw VPSConnectionError.invalidURL(rawValue)
        }

        let scheme = components.scheme?.lowercased() ?? "https"
        guard scheme == "http" || scheme == "https" else {
            throw VPSConnectionError.unsupportedScheme(scheme)
        }

        guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            throw VPSConnectionError.missingHost
        }

        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else {
            throw VPSConnectionError.invalidPort
        }

        let normalizedPath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedVPSPanelURL(
            useTLS: scheme == "https",
            host: host,
            port: port,
            basePath: normalizedPath
        )
    }
}
