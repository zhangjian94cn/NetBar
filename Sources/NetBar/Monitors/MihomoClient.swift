import Foundation

/// Mihomo (Clash) 代理核心连接信息 API 客户端
/// 通过 Unix Socket 或 HTTP Controller 获取代理连接快照
enum MihomoClient {

    // MARK: - Configuration (from AppConfig)

    private static var socketPath: String { AppConfig.shared.mihomoSocketPath }
    private static var controllerURL: String { AppConfig.shared.mihomoControllerURL }
    private static var secret: String { AppConfig.shared.mihomoSecret }

    // MARK: - Public Types

    /// 单个连接的快照数据
    struct ConnectionSnapshot {
        let appName: String
        let bytesIn: UInt64
        let bytesOut: UInt64
        /// true = 直连（DIRECT），false = 经代理
        let isDirect: Bool
        let startDate: Date?
    }

    struct RuntimeConfiguration: Equatable {
        let mixedPort: Int
        let tunEnabled: Bool
        let ipv6Enabled: Bool
        let routeExclusions: Set<String>
    }

    // MARK: - Public API

    /// 获取当前所有 Mihomo 连接的快照，key 为连接 ID
    static func fetchConnectionSnapshots() -> [String: ConnectionSnapshot]? {
        guard let data = fetchConnectionsData() else { return nil }

        do {
            let response = try JSONDecoder().decode(ConnectionsResponse.self, from: data)
            var snapshots: [String: ConnectionSnapshot] = [:]

            for connection in response.connections {
                let appName = appNameFromMetadata(connection.metadata)
                guard !appName.isEmpty else { continue }

                snapshots[connection.id] = ConnectionSnapshot(
                    appName: appName,
                    bytesIn: connection.download,
                    bytesOut: connection.upload,
                    isDirect: checkIsDirect(connection),
                    startDate: parseDate(connection.start)
                )
            }

            return snapshots
        } catch {
            return nil
        }
    }

    static func runtimeConfiguration() -> RuntimeConfiguration? {
        guard let data = fetchControllerData(path: "/configs", timeout: "2"),
              let response = try? JSONDecoder().decode(RuntimeConfigurationResponse.self, from: data) else {
            return nil
        }
        return RuntimeConfiguration(
            mixedPort: response.mixedPort,
            tunEnabled: response.tun?.enable ?? false,
            ipv6Enabled: response.ipv6 ?? false,
            routeExclusions: Set(
                (response.tun?.routeExcludeAddress ?? []) +
                (response.tun?.inet4RouteExcludeAddress ?? [])
            )
        )
    }

    static func setTunEnabled(_ enabled: Bool) -> Bool {
        #if APP_STORE
        return false
        #else
        guard FileManager.default.fileExists(atPath: socketPath),
              let body = try? JSONSerialization.data(withJSONObject: ["tun": ["enable": enabled]]),
              let bodyString = String(data: body, encoding: .utf8) else {
            return false
        }
        var arguments = [
            "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "--max-time", "4", "-X", "PATCH",
            "--unix-socket", socketPath,
            "-H", "Content-Type: application/json"
        ]
        if !secret.isEmpty { arguments += ["-H", "Authorization: Bearer \(secret)"] }
        arguments += ["--data-binary", bodyString, controllerEndpoint(path: "/configs", useUnixHost: true)]
        let result = runCurlCommand(arguments: arguments)
        let status = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return result.exitCode == 0 && status == 204
        #endif
    }

    static func probeHTTPS() -> Bool {
        guard let configuration = runtimeConfiguration(), configuration.mixedPort > 0 else { return false }
        let result = runCurlCommand(arguments: [
            "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "2", "--max-time", "4",
            "--proxy", "http://127.0.0.1:\(configuration.mixedPort)",
            "https://cp.cloudflare.com/generate_204"
        ])
        guard result.exitCode == 0,
              let status = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return (200..<400).contains(status)
    }

    /// Close only Mihomo's active connections so new dials follow the new underlay.
    /// This does not reload configuration, toggle TUN, or restart the core process.
    static func closeAllConnections() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        var arguments = [
            "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "--max-time", "2", "-X", "DELETE",
            "--unix-socket", socketPath
        ]
        if !secret.isEmpty {
            arguments += ["-H", "Authorization: Bearer \(secret)"]
        }
        arguments.append(controllerEndpoint(path: "/connections", useUnixHost: true))
        let result = runCurlCommand(arguments: arguments)
        let status = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return result.exitCode == 0 && status == 204
    }

    // MARK: - Network

    private static func fetchConnectionsData() -> Data? {
        if FileManager.default.fileExists(atPath: socketPath),
           let data = runCurl(arguments: [
                "-sS", "--max-time", "1",
                "--unix-socket", socketPath,
                "-H", "Authorization: Bearer \(secret)",
                "http://unix/connections"
           ]) {
            return data
        }

        return runCurl(arguments: [
            "-sS", "--max-time", "1",
            "-H", "Authorization: Bearer \(secret)",
            controllerURL
        ])
    }

    private static func fetchControllerData(path: String, timeout: String) -> Data? {
        var arguments = ["-sS", "--max-time", timeout]
        let useSocket = FileManager.default.fileExists(atPath: socketPath)
        if useSocket { arguments += ["--unix-socket", socketPath] }
        if !secret.isEmpty { arguments += ["-H", "Authorization: Bearer \(secret)"] }
        arguments.append(controllerEndpoint(path: path, useUnixHost: useSocket))
        return runCurl(arguments: arguments)
    }

    private static func controllerEndpoint(path: String, useUnixHost: Bool) -> String {
        if useUnixHost { return "http://unix\(path)" }
        guard var components = URLComponents(string: controllerURL) else { return controllerURL }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? controllerURL
    }

    private static func runCurl(arguments: [String]) -> Data? {
        let result = runCurlCommand(arguments: arguments)
        guard result.exitCode == 0, let data = result.output.data(using: .utf8), !data.isEmpty else { return nil }
        return data
    }

    private static func runCurlCommand(arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, "")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Parsing

    private static func appNameFromMetadata(_ metadata: ConnectionMetadata) -> String {
        if let processPath = metadata.processPath,
           let appName = appBundleName(from: processPath) {
            return appName
        }

        if let process = metadata.process?.trimmingCharacters(in: .whitespacesAndNewlines),
           !process.isEmpty {
            return NettopParser.extractAppName(from: process)
        }

        if let host = metadata.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }

        return "未知代理应用"
    }

    private static func appBundleName(from processPath: String) -> String? {
        for component in processPath.split(separator: "/") {
            guard component.hasSuffix(".app") else { continue }
            return String(component.dropLast(4))
        }
        return nil
    }

    private static func checkIsDirect(_ connection: Connection) -> Bool {
        connection.chains?.contains(where: { $0.localizedCaseInsensitiveContains("DIRECT") }) == true
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    // MARK: - Decodable Types

    private struct ConnectionsResponse: Decodable {
        let connections: [Connection]
    }

    private struct RuntimeConfigurationResponse: Decodable {
        struct Tun: Decodable {
            let enable: Bool?
            let routeExcludeAddress: [String]?
            let inet4RouteExcludeAddress: [String]?

            enum CodingKeys: String, CodingKey {
                case enable
                case routeExcludeAddress = "route-exclude-address"
                case inet4RouteExcludeAddress = "inet4-route-exclude-address"
            }
        }
        let mixedPort: Int
        let tun: Tun?
        let ipv6: Bool?

        enum CodingKeys: String, CodingKey {
            case mixedPort = "mixed-port"
            case tun
            case ipv6
        }
    }

    private struct Connection: Decodable {
        let id: String
        let metadata: ConnectionMetadata
        let upload: UInt64
        let download: UInt64
        let start: String?
        let chains: [String]?
    }

    private struct ConnectionMetadata: Decodable {
        let process: String?
        let processPath: String?
        let host: String?
    }
}
