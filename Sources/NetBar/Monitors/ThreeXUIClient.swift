import Foundation

struct ThreeXUIInboundData {
    let up: UInt64
    let down: UInt64
    let allTime: UInt64
    let total: UInt64
    let protocol_: String
    let port: Int
    let clients: [ThreeXUIClientData]

    init?(from dict: [String: Any]) {
        guard let up = Self.uint64Value(dict["up"]),
              let down = Self.uint64Value(dict["down"]) else { return nil }
        self.up = up
        self.down = down
        self.allTime = Self.uint64Value(dict["allTime"]) ?? up + down
        self.total = Self.uint64Value(dict["total"]) ?? 0
        self.protocol_ = dict["protocol"] as? String ?? ""
        self.port = dict["port"] as? Int ?? 0

        if let stats = dict["clientStats"] as? [[String: Any]] {
            self.clients = stats.compactMap { ThreeXUIClientData(from: $0) }
        } else {
            self.clients = []
        }
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? Int64, value >= 0 { return UInt64(value) }
        if let value = value as? Double, value >= 0 { return UInt64(value) }
        if let value = value as? NSNumber, value.int64Value >= 0 { return UInt64(value.int64Value) }
        return nil
    }
}

struct ThreeXUIClientData {
    let email: String
    let up: UInt64
    let down: UInt64
    let allTime: UInt64
    let lastOnline: Int64

    init?(from dict: [String: Any]) {
        guard let email = dict["email"] as? String else { return nil }
        self.email = email
        self.up = Self.uint64Value(dict["up"]) ?? 0
        self.down = Self.uint64Value(dict["down"]) ?? 0
        self.allTime = Self.uint64Value(dict["allTime"]) ?? 0
        self.lastOnline = Self.int64Value(dict["lastOnline"]) ?? 0
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? Int64, value >= 0 { return UInt64(value) }
        if let value = value as? Double, value >= 0 { return UInt64(value) }
        if let value = value as? NSNumber, value.int64Value >= 0 { return UInt64(value.int64Value) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}

final class ThreeXUIClient {
    private let injectedSession: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 10) {
        self.injectedSession = session
        self.timeout = timeout
    }

    func testConnection(config: AppConfig.VPSConfig, password: String) async -> ConnectionTestResult {
        do {
            let cookie = try await login(config: config, password: password)
            _ = try await fetchInbounds(config: config, cookie: cookie)
            return .success
        } catch {
            return .failure(error)
        }
    }

    func login(config: AppConfig.VPSConfig, password: String) async throws -> String {
        guard !password.isEmpty else {
            throw VPSConnectionError.passwordRequired
        }

        let url = try makeURL(config: config, pathComponents: ["login"])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody(username: config.username, password: password)

        let (data, response) = try await perform(request, config: config)
        try validateHTTP(response, data: data, for: .login)

        let json = try parseJSONObject(data)
        guard let success = json["success"] as? Bool else {
            throw VPSConnectionError.invalidResponse
        }
        guard success else {
            throw VPSConnectionError.invalidCredentials(responseMessage(from: json))
        }

        guard let httpResponse = response as? HTTPURLResponse,
              let setCookie = setCookieHeader(from: httpResponse),
              let cookie = setCookie.components(separatedBy: ";").first,
              !cookie.isEmpty else {
            throw VPSConnectionError.missingCookie
        }
        return cookie
    }

    func fetchInbounds(config: AppConfig.VPSConfig, cookie: String) async throws -> [ThreeXUIInboundData] {
        let url = try makeURL(config: config, pathComponents: ["panel", "api", "inbounds", "list"])
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let (data, response) = try await perform(request, config: config)
        try validateHTTP(response, data: data, for: .inbounds)

        let json = try parseJSONObject(data)
        guard let success = json["success"] as? Bool else {
            throw VPSConnectionError.invalidResponse
        }
        guard success else {
            throw VPSConnectionError.inboundsAPIIncompatible
        }
        guard let obj = json["obj"] as? [[String: Any]] else {
            throw VPSConnectionError.inboundsAPIIncompatible
        }
        return obj.compactMap { ThreeXUIInboundData(from: $0) }
    }

    static func formEncodedBody(username: String, password: String) -> Data? {
        let body = [
            "username=\(formEncode(username))",
            "password=\(formEncode(password))"
        ].joined(separator: "&")
        return body.data(using: .utf8)
    }

    private static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._* ")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            .replacingOccurrences(of: " ", with: "+")
    }

    private enum Endpoint {
        case login
        case inbounds
    }

    private func makeURL(config: AppConfig.VPSConfig, pathComponents: [String]) throws -> URL {
        var components = URLComponents()
        components.scheme = config.useTLS ? "https" : "http"
        components.host = config.host
        components.port = config.port

        let baseSegments = config.basePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        let path = (baseSegments + pathComponents).joined(separator: "/")
        components.path = "/\(path)"

        guard let url = components.url else {
            throw VPSConnectionError.invalidURL(config.panelURL)
        }
        return url
    }

    private func perform(_ request: URLRequest, config: AppConfig.VPSConfig) async throws -> (Data, URLResponse) {
        do {
            return try await session(for: config).data(for: request)
        } catch {
            throw mapTransportError(error)
        }
    }

    private func session(for config: AppConfig.VPSConfig) -> URLSession {
        if let injectedSession {
            return injectedSession
        }
        if config.allowSelfSignedCertificate {
            return InsecureURLSession.create(timeout: timeout)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private func validateHTTP(_ response: URLResponse, data: Data, for endpoint: Endpoint) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VPSConnectionError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401, 403:
            throw VPSConnectionError.invalidCredentials(nil)
        case 404:
            throw VPSConnectionError.pathNotFound
        default:
            if endpoint == .login,
               let json = try? parseJSONObject(data),
               let success = json["success"] as? Bool,
               !success {
                throw VPSConnectionError.invalidCredentials(responseMessage(from: json))
            }
            throw VPSConnectionError.httpStatus(httpResponse.statusCode)
        }
    }

    private func parseJSONObject(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VPSConnectionError.invalidResponse
        }
        return json
    }

    private func responseMessage(from json: [String: Any]) -> String? {
        json["msg"] as? String ?? json["message"] as? String
    }

    private func setCookieHeader(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                continue
            }
            return value as? String
        }
        return nil
    }

    private func mapTransportError(_ error: Error) -> VPSConnectionError {
        guard let urlError = error as? URLError else {
            return VPSConnectionError.unknown(error.localizedDescription)
        }

        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
            return .networkUnavailable
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .secureConnectionFailed:
            return .tlsCertificateFailed
        default:
            return .unknown(urlError.localizedDescription)
        }
    }
}
