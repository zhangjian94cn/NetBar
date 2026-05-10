import Foundation

/// nettop 命令执行与输出解析器
/// 将系统 nettop 工具的调用和文本解析从 ProcessTrafficMonitor 中解耦
enum NettopParser {

    struct Result {
        var stats: [String: (bytesIn: UInt64, bytesOut: UInt64)]
        var interfaces: [String: Set<String>]
    }

    /// 从进程名（如 "Safari.1234"）中提取应用名（如 "Safari"）
    static func extractAppName(from processKey: String) -> String {
        let parts = processKey.split(separator: ".")
        if parts.count >= 2, let _ = Int(parts.last!) {
            return parts.dropLast().joined(separator: ".")
        }
        return processKey
    }

    /// 同步执行一次 nettop 并解析输出
    static func fetch() -> Result {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-x", "-l", "1", "-J", "bytes_in,bytes_out,interface"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return Result(stats: [:], interfaces: [:]) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return Result(stats: [:], interfaces: [:])
        }
        return parse(output)
    }

    /// 解析 nettop 文本输出
    static func parse(_ output: String) -> Result {
        var summaryStats: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var connectionStats: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var processesWithConnectionStats: Set<String> = []
        var interfaces: [String: Set<String>] = [:]
        var currentProcess: String? = nil

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("bytes_in") else { continue }

            let isConnectionLine = line.hasPrefix("   ") || line.hasPrefix("\t")

            if !isConnectionLine {
                let components = trimmed.split(separator: " ").map { String($0) }
                guard components.count >= 3 else { continue }

                let processName = components[0]
                guard let bytesOut = UInt64(components[components.count - 1]),
                      let bytesIn = UInt64(components[components.count - 2]) else { continue }

                if components.count >= 4 {
                    let ifaceName = components[components.count - 3]
                    if !ifaceName.contains(".") {
                        let appName = extractAppName(from: processName)
                        interfaces[appName, default: Set()].insert(ifaceName)
                    }
                }

                currentProcess = processName
                summaryStats[processName] = (bytesIn: bytesIn, bytesOut: bytesOut)

            } else if let proc = currentProcess {
                guard let parsed = parseConnectionTrafficLine(trimmed) else { continue }

                processesWithConnectionStats.insert(proc)
                if let iface = parsed.interface {
                    let appName = extractAppName(from: proc)
                    interfaces[appName, default: Set()].insert(iface)
                }

                guard shouldCountRawConnection(line: trimmed, interface: parsed.interface) else {
                    continue
                }

                if let existing = connectionStats[proc] {
                    connectionStats[proc] = (
                        existing.bytesIn + parsed.bytesIn,
                        existing.bytesOut + parsed.bytesOut
                    )
                } else {
                    connectionStats[proc] = (parsed.bytesIn, parsed.bytesOut)
                }
            }
        }

        var stats = connectionStats
        for (processName, summary) in summaryStats where !processesWithConnectionStats.contains(processName) {
            stats[processName] = summary
        }

        return Result(stats: stats, interfaces: interfaces)
    }

    // MARK: - Private Helpers

    private static func parseConnectionTrafficLine(_ line: String) -> (
        interface: String?,
        bytesIn: UInt64,
        bytesOut: UInt64
    )? {
        let components = line.split(separator: " ").map { String($0) }
        guard components.count >= 3,
              let bytesOut = UInt64(components[components.count - 1]),
              let bytesIn = UInt64(components[components.count - 2]) else {
            return nil
        }

        let interfaceCandidate = components[components.count - 3]
        let interface = isInterfaceName(interfaceCandidate) ? interfaceCandidate : nil
        return (interface, bytesIn, bytesOut)
    }

    /// 判断原始连接行是否应计入统计（排除 loopback 和代理 fake-IP 流量）
    private static func shouldCountRawConnection(line: String, interface: String?) -> Bool {
        guard interface != "lo0" else { return false }
        guard !line.contains("198.18.") else { return false }
        guard !line.contains("fdfe:dcba:9876") else { return false }
        return true
    }

    private static func isInterfaceName(_ value: String) -> Bool {
        value == "lo0" ||
            value.hasPrefix("en") ||
            value.hasPrefix("awdl") ||
            value.hasPrefix("llw") ||
            value.hasPrefix("utun") ||
            value.hasPrefix("ipsec") ||
            value.hasPrefix("ppp") ||
            value.hasPrefix("tap") ||
            value.hasPrefix("tun") ||
            value.hasPrefix("bridge")
    }
}
