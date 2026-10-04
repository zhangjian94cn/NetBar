import Foundation
import Darwin

/// nettop 命令执行与输出解析器
/// 将系统 nettop 工具的调用和文本解析从 ProcessTrafficMonitor 中解耦
enum NettopParser {
    private static let timeoutQueue = DispatchQueue(label: "com.zjah.NetBar.nettopParser.timeout", qos: .utility)
    private static let summaryTimeout: TimeInterval = 2
    private static let detailedTimeout: TimeInterval = 20

    /// 在飞 nettop 子进程注册表：App 退出时统一回收，避免孤儿进程残留烧 CPU。
    /// nettop 偶发不退出（2026-05-07、2026-10-04 两次事故），父进程死后它会被
    /// launchd 收养继续跑，macOS 不会自动回收，必须显式杀。
    private static let childLock = NSLock()
    private static var runningChildren: Set<pid_t> = []

    /// 杀掉当前在飞的所有 nettop 子进程（App 退出时调用）
    static func terminateAllRunningChildren() {
        childLock.lock()
        let pids = runningChildren
        runningChildren.removeAll()
        childLock.unlock()
        for pid in pids where pid > 0 {
            kill(pid, SIGKILL)
        }
    }

    /// 清扫上次运行遗留的孤儿 nettop：只杀父进程已死（ppid == 1）的挂死采样进程，
    /// 不碰用户自己在终端里跑的 nettop。
    static func sweepOrphanedNettopProcesses() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return }

        for line in output.components(separatedBy: "\n") {
            if let pid = orphanedNettopPID(psLine: line) {
                kill(pid, SIGKILL)
            }
        }
    }

    /// 解析 `ps -axo pid=,ppid=,comm=` 的一行，是孤儿 nettop 则返回其 pid，否则 nil
    static func orphanedNettopPID(psLine line: String) -> pid_t? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 3,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              ppid == 1,
              parts[2...].joined(separator: " ").hasSuffix("/nettop") else { return nil }
        return pid
    }

    private static func registerChild(_ pid: pid_t) {
        childLock.lock()
        runningChildren.insert(pid)
        childLock.unlock()
    }

    private static func unregisterChild(_ pid: pid_t) {
        childLock.lock()
        runningChildren.remove(pid)
        childLock.unlock()
    }

    struct Result {
        var stats: [String: (bytesIn: UInt64, bytesOut: UInt64)]
        var interfaces: [String: Set<String>]
    }

    /// 从进程名（如 "Safari.1234"）中提取应用名（如 "Safari"）
    static func extractAppName(from processKey: String) -> String {
        let parts = processKey.split(separator: ".")
        if parts.count >= 2, let _ = Int(parts.last!) {
            return parts.dropLast().joined(separator: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return processKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 快速获取每个进程的汇总计数。用于诊断或需要包含本地接口的场景。
    static func fetchSummary() -> Result {
        fetch(summaryOnly: true)
    }

    /// 获取非 loopback 接口上的进程汇总计数。
    /// 实时活跃列表使用这个入口，避免把浏览器 -> 本地代理的 127.0.0.1 回环流量算成外网下载。
    static func fetchExternalSummary() -> Result {
        fetch(summaryOnly: true, interfaceType: "external")
    }

    /// 获取连接明细。仅适合低频后台刷新路由信息，不应放在实时刷新路径上。
    static func fetchDetailed() -> Result {
        fetch(summaryOnly: false)
    }

    /// 同步执行一次 nettop 并解析输出。保留旧调用形态，默认使用明细模式。
    static func fetch() -> Result {
        fetchDetailed()
    }

    private static func fetch(summaryOnly: Bool, interfaceType: String? = nil) -> Result {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        var arguments = ["-n", "-x"]
        if let interfaceType {
            arguments += ["-t", interfaceType]
        }
        if summaryOnly {
            arguments.append("-P")
        }
        arguments += ["-l", "1", "-J", "bytes_in,bytes_out,interface"]
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            registerChild(process.processIdentifier)
        } catch { return Result(stats: [:], interfaces: [:]) }

        let timeout = summaryOnly ? summaryTimeout : detailedTimeout
        let timeoutLock = NSLock()
        var didTimeOut = false
        let timeoutWorkItem = DispatchWorkItem {
            timeoutLock.lock()
            didTimeOut = true
            timeoutLock.unlock()

            guard process.isRunning else { return }
            process.terminate()
            timeoutQueue.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        unregisterChild(process.processIdentifier)
        timeoutWorkItem.cancel()

        timeoutLock.lock()
        let timedOut = didTimeOut
        timeoutLock.unlock()
        guard !timedOut else { return Result(stats: [:], interfaces: [:]) }

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
                guard let parsed = parseProcessSummaryLine(trimmed) else { continue }

                if let ifaceName = parsed.interface {
                    let appName = extractAppName(from: parsed.processName)
                    interfaces[appName, default: Set()].insert(ifaceName)
                }

                currentProcess = parsed.processName
                summaryStats[parsed.processName] = (bytesIn: parsed.bytesIn, bytesOut: parsed.bytesOut)

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

    private static func parseProcessSummaryLine(_ line: String) -> (
        processName: String,
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

        let interfaceCandidate = components.count >= 4 ? components[components.count - 3] : ""
        let hasInterface = isInterfaceName(interfaceCandidate)
        let processComponents = hasInterface
            ? components.dropLast(3)
            : components.dropLast(2)
        let processName = processComponents.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !processName.isEmpty else { return nil }
        return (processName, hasInterface ? interfaceCandidate : nil, bytesIn, bytesOut)
    }

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
