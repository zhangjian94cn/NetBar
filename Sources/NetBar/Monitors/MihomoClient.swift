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

    private static func runCurl(arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
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
