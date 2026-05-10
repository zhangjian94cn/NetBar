import Foundation

final class Ping0IPClient: IPIntelligenceClient {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    func lookupCurrentIP(version: IPVersion, apiKey: String?) async throws -> EgressIPInfo {
        let baseInfo = try await fetchGeo(version: version)
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return baseInfo
        }

        let detailedInfo = try await lookup(ip: baseInfo.ip, apiKey: apiKey)
        return EgressIPInfo(
            ip: detailedInfo.ip,
            ipVersion: baseInfo.ipVersion,
            location: detailedInfo.location ?? baseInfo.location,
            country: detailedInfo.country,
            province: detailedInfo.province,
            city: detailedInfo.city,
            asn: detailedInfo.asn ?? baseInfo.asn,
            asnName: detailedInfo.asnName,
            org: detailedInfo.org ?? baseInfo.org,
            isIDC: detailedInfo.isIDC,
            ipRisk: detailedInfo.ipRisk,
            isNative: detailedInfo.isNative,
            asnType: detailedInfo.asnType,
            orgType: detailedInfo.orgType,
            source: "ping0",
            fetchedAt: Date()
        )
    }

    func lookup(ip: String, apiKey: String) async throws -> EgressIPInfo {
        guard let url = Self.detailURL(ip: ip, apiKey: apiKey) else {
            throw EgressIPError.invalidEndpoint
        }

        let data = try await fetch(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EgressIPError.invalidJSONResponse
        }
        return try Self.parseDetailJSON(json, fetchedAt: Date())
    }

    static func geoURL(for version: IPVersion) -> URL {
        switch version {
        case .auto:
            return URL(string: "https://ping0.cc/geo")!
        case .ipv4:
            return URL(string: "https://ipv4.ping0.cc/geo")!
        case .ipv6:
            return URL(string: "https://ipv6.ping0.cc/geo")!
        }
    }

    static func detailURL(ip: String, apiKey: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed
        guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedIP = ip.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "https://ping0.cc/apiloc/apikey(\(encodedKey))/ip(\(encodedIP))")
    }

    static func parseGeoResponse(_ text: String, fetchedAt: Date = Date()) throws -> EgressIPInfo {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 4 else {
            throw EgressIPError.invalidGeoResponse
        }

        let ip = lines[0]
        return EgressIPInfo(
            ip: ip,
            ipVersion: ip.contains(":") ? .ipv6 : .ipv4,
            location: lines[1],
            country: nil,
            province: nil,
            city: nil,
            asn: lines[2],
            asnName: nil,
            org: lines[3],
            isIDC: nil,
            ipRisk: nil,
            isNative: nil,
            asnType: nil,
            orgType: nil,
            source: "ping0",
            fetchedAt: fetchedAt
        )
    }

    static func parseDetailJSON(_ json: [String: Any], fetchedAt: Date = Date()) throws -> EgressIPInfo {
        guard let ip = json["ip"] as? String else {
            throw EgressIPError.invalidJSONResponse
        }

        return EgressIPInfo(
            ip: ip,
            ipVersion: ip.contains(":") ? .ipv6 : .ipv4,
            location: json["location"] as? String,
            country: json["country"] as? String,
            province: json["province"] as? String,
            city: json["city"] as? String,
            asn: json["asn"] as? String,
            asnName: json["asnname"] as? String,
            org: json["org"] as? String,
            isIDC: json["isidc"] as? Bool,
            ipRisk: intValue(json["iprisk"]),
            isNative: json["isnative"] as? Bool,
            asnType: json["asntype"] as? String,
            orgType: json["orgtype"] as? String,
            source: "ping0",
            fetchedAt: fetchedAt
        )
    }

    private func fetchGeo(version: IPVersion) async throws -> EgressIPInfo {
        let data = try await fetch(url: Self.geoURL(for: version))
        guard let text = String(data: data, encoding: .utf8) else {
            throw EgressIPError.invalidGeoResponse
        }
        return try Self.parseGeoResponse(text)
    }

    private func fetch(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EgressIPError.invalidGeoResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw EgressIPError.httpStatus(httpResponse.statusCode)
            }
            return data
        } catch let error as EgressIPError {
            throw error
        } catch {
            throw mapTransportError(error)
        }
    }

    private func mapTransportError(_ error: Error) -> EgressIPError {
        guard let urlError = error as? URLError else {
            return .unknown(error.localizedDescription)
        }

        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
            return .networkUnavailable
        default:
            return .unknown(urlError.localizedDescription)
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
