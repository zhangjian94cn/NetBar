import CryptoKit
import Combine
import Foundation

enum ClashOverlayMode: String, Codable, Equatable {
    case systemProxy
    case tunFull

    var displayName: String {
        switch self {
        case .systemProxy: return "系统代理"
        case .tunFull: return "TUN 全局"
        }
    }
}

enum ClashOverlayHealth: String, Equatable {
    case unavailable
    case configurationDrift
    case switching
    case ready
    case degraded

    var displayName: String {
        switch self {
        case .unavailable: return "Clash 控制面不可用"
        case .configurationDrift: return "共存基线需要修复"
        case .switching: return "正在切换"
        case .ready: return "数据面正常"
        case .degraded: return "代理数据面未收敛"
        }
    }
}

struct ClashOverlaySnapshot: Equatable {
    let mode: ClashOverlayMode?
    let runtimeTunEnabled: Bool?
    let persistentTunEnabled: Bool?
    let systemProxyEnabled: Bool
    let coexistenceBaselineReady: Bool
    let dataPlaneReady: Bool
    let health: ClashOverlayHealth
    let reason: String?
}

#if !APP_STORE

protocol ClashRuntimeControlling {
    func configuration() -> MihomoClient.RuntimeConfiguration?
    func setTunEnabled(_ enabled: Bool) -> Bool
    func closeAllConnections() -> Bool
    func probeHTTPS() -> Bool
}

struct LiveClashRuntimeController: ClashRuntimeControlling {
    func configuration() -> MihomoClient.RuntimeConfiguration? { MihomoClient.runtimeConfiguration() }
    func setTunEnabled(_ enabled: Bool) -> Bool { MihomoClient.setTunEnabled(enabled) }
    func closeAllConnections() -> Bool { MihomoClient.closeAllConnections() }
    func probeHTTPS() -> Bool { MihomoClient.probeHTTPS() }
}

protocol VergeTunPreferenceStoring {
    func read() throws -> Bool
    func replace(with enabled: Bool) throws -> VergeTunPreferenceTransaction
    func rollback(_ transaction: VergeTunPreferenceTransaction) throws
    func commit(_ transaction: VergeTunPreferenceTransaction) throws
}

struct VergeTunPreferenceTransaction: Equatable {
    let id: String
    let originalData: Data
    let originalDigest: String
    let appliedDigest: String
    let originalPermissions: Int
    let backupURL: URL
}

enum VergeTunPreferenceError: LocalizedError, Equatable {
    case missing
    case ambiguous
    case invalidValue
    case changedDuringTransaction

    var errorDescription: String? {
        switch self {
        case .missing: return "未找到 Clash Verge 持久配置"
        case .ambiguous: return "enable_tun_mode 字段不是唯一值"
        case .invalidValue: return "enable_tun_mode 不是布尔值"
        case .changedDuringTransaction: return "配置在事务期间被其他程序修改"
        }
    }
}

final class LiveVergeTunPreferenceStore: VergeTunPreferenceStoring {
    private let configURL: URL
    private let transactionRoot: URL

    init(
        configURL: URL? = nil,
        transactionRoot: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configURL = configURL ?? home
            .appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge.yaml")
        self.transactionRoot = transactionRoot ?? home
            .appendingPathComponent("Library/Application Support/NetBar/OverlayTransactions", isDirectory: true)
    }

    func read() throws -> Bool {
        try Self.parse(data: Data(contentsOf: configURL)).value
    }

    func replace(with enabled: Bool) throws -> VergeTunPreferenceTransaction {
        let original = try Data(contentsOf: configURL)
        let originalPermissions = (try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let parsed = try Self.parse(data: original)
        let id = UUID().uuidString.lowercased()
        let directory = transactionRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let backup = directory.appendingPathComponent("verge.yaml")
        try original.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        let digest = Self.digest(original)
        let manifest: [String: String] = ["id": id, "sha256": digest]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

        var lines = parsed.lines
        lines[parsed.index] = "enable_tun_mode: \(enabled ? "true" : "false")"
        let output = Data((lines.joined(separator: "\n") + (parsed.hadTrailingNewline ? "\n" : "")).utf8)
        try output.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: configURL.path)
        return .init(
            id: id,
            originalData: original,
            originalDigest: digest,
            appliedDigest: Self.digest(output),
            originalPermissions: originalPermissions,
            backupURL: backup
        )
    }

    func rollback(_ transaction: VergeTunPreferenceTransaction) throws {
        let current = try Data(contentsOf: configURL)
        let currentDigest = Self.digest(current)
        if currentDigest == transaction.originalDigest { return }
        guard currentDigest == transaction.appliedDigest else {
            throw VergeTunPreferenceError.changedDuringTransaction
        }
        let backup = try Data(contentsOf: transaction.backupURL)
        guard Self.digest(backup) == transaction.originalDigest else {
            throw VergeTunPreferenceError.changedDuringTransaction
        }
        try backup.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: transaction.originalPermissions], ofItemAtPath: configURL.path)
    }

    func commit(_ transaction: VergeTunPreferenceTransaction) throws {
        let current = try Data(contentsOf: configURL)
        guard Self.digest(current) == transaction.appliedDigest else {
            throw VergeTunPreferenceError.changedDuringTransaction
        }
        _ = try Self.parse(data: current)
        let manifestURL = transaction.backupURL.deletingLastPathComponent().appendingPathComponent("committed")
        try Data(Self.digest(current).utf8).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    private static func parse(data: Data) throws -> (value: Bool, lines: [String], index: Int, hadTrailingNewline: Bool) {
        guard let text = String(data: data, encoding: .utf8) else { throw VergeTunPreferenceError.invalidValue }
        let lines = text.components(separatedBy: .newlines)
        let matches = lines.enumerated().filter { _, line in
            line.hasPrefix("enable_tun_mode:")
        }
        guard !matches.isEmpty else { throw VergeTunPreferenceError.missing }
        guard matches.count == 1, let match = matches.first else { throw VergeTunPreferenceError.ambiguous }
        let raw = match.element.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw == "true" || raw == "false" else { throw VergeTunPreferenceError.invalidValue }
        var normalizedLines = lines
        let trailing = text.hasSuffix("\n")
        if trailing, normalizedLines.last == "" { normalizedLines.removeLast() }
        return (raw == "true", normalizedLines, match.offset, trailing)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

protocol SystemProxyInspecting {
    func isEnabled(expectedPort: Int) -> Bool
}

protocol SystemHTTPSProbing {
    func probeHTTPS() -> Bool
}

struct LiveSystemHTTPSProbe: SystemHTTPSProbing {
    func probeHTTPS() -> Bool {
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var succeeded = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lock.lock()
            succeeded = (200..<400).contains(status)
            lock.unlock()
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 7) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }
}

struct LiveSystemProxyInspector: SystemProxyInspecting {
    func isEnabled(expectedPort: Int) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--proxy"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return false }
        let enabled = output.contains("HTTPEnable : 1") ||
            output.contains("HTTPSEnable : 1") || output.contains("SOCKSEnable : 1")
        let loopback = output.contains("HTTPProxy : 127.0.0.1") ||
            output.contains("HTTPSProxy : 127.0.0.1") || output.contains("SOCKSProxy : 127.0.0.1") ||
            output.contains("HTTPProxy : localhost") || output.contains("HTTPSProxy : localhost")
        let port = output.contains("HTTPPort : \(expectedPort)") ||
            output.contains("HTTPSPort : \(expectedPort)") || output.contains("SOCKSPort : \(expectedPort)")
        return enabled && loopback && port
    }
}

final class ClashOverlayModeController: ObservableObject {
    @Published private(set) var snapshot = ClashOverlaySnapshot(
        mode: nil,
        runtimeTunEnabled: nil,
        persistentTunEnabled: nil,
        systemProxyEnabled: false,
        coexistenceBaselineReady: false,
        dataPlaneReady: false,
        health: .unavailable,
        reason: nil
    )
    @Published private(set) var isSwitching = false

    private static let requiredExclusions: Set<String> = [
        "10.0.0.0/8", "100.64.0.0/10", "172.16.0.0/12", "192.168.0.0/16",
        "192.200.0.0/24", "199.165.136.0/24", "119.45.14.85/32", "124.222.119.248/32"
    ]
    private let runtime: ClashRuntimeControlling
    private let preferenceStore: VergeTunPreferenceStoring
    private let proxyInspector: SystemProxyInspecting
    private let systemHTTPSProbe: SystemHTTPSProbing
    private let queue = DispatchQueue(label: "com.zjah.NetBar.clash-overlay", qos: .userInitiated)

    init(
        runtime: ClashRuntimeControlling = LiveClashRuntimeController(),
        preferenceStore: VergeTunPreferenceStoring = LiveVergeTunPreferenceStore(),
        proxyInspector: SystemProxyInspecting = LiveSystemProxyInspector(),
        systemHTTPSProbe: SystemHTTPSProbing = LiveSystemHTTPSProbe()
    ) {
        self.runtime = runtime
        self.preferenceStore = preferenceStore
        self.proxyInspector = proxyInspector
        self.systemHTTPSProbe = systemHTTPSProbe
    }

    func refresh() {
        queue.async { [weak self] in self?.publishCurrentSnapshot() }
    }

    func switchMode(to target: ClashOverlayMode) {
        guard !isSwitching, DistributionFlavor.current.supportsClashModeSwitch else { return }
        isSwitching = true
        snapshot = .init(
            mode: snapshot.mode,
            runtimeTunEnabled: snapshot.runtimeTunEnabled,
            persistentTunEnabled: snapshot.persistentTunEnabled,
            systemProxyEnabled: snapshot.systemProxyEnabled,
            coexistenceBaselineReady: snapshot.coexistenceBaselineReady,
            dataPlaneReady: snapshot.dataPlaneReady,
            health: .switching,
            reason: nil
        )
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.apply(target)
            DispatchQueue.main.async {
                self.snapshot = result
                self.isSwitching = false
            }
        }
    }

    private func apply(_ target: ClashOverlayMode) -> ClashOverlaySnapshot {
        guard let originalRuntime = runtime.configuration() else {
            return failedSnapshot(.unavailable, "Clash/Mihomo 控制面不可用")
        }
        let proxyEnabled = proxyInspector.isEnabled(expectedPort: originalRuntime.mixedPort)
        guard proxyEnabled else {
            return failedSnapshot(.configurationDrift, "系统代理未开启；NetBar 不会代替用户修改代理开关")
        }
        if target == .tunFull, !Self.baselineReady(originalRuntime) {
            return failedSnapshot(.configurationDrift, "TUN 共存基线不完整，请先修复 IPv6 与 aTrust/LAN/Tailscale/WireGuard 排除规则")
        }
        let expected = target == .tunFull
        if originalRuntime.tunEnabled == expected,
           (try? preferenceStore.read()) == expected {
            let dataPlaneReady = runtime.probeHTTPS() && systemHTTPSProbe.probeHTTPS()
            return makeSnapshot(
                runtime: originalRuntime,
                persistent: expected,
                proxyEnabled: true,
                dataPlaneReady: dataPlaneReady
            )
        }

        let transaction: VergeTunPreferenceTransaction
        do {
            transaction = try preferenceStore.replace(with: expected)
        } catch {
            return failedSnapshot(.configurationDrift, error.localizedDescription)
        }
        guard runtime.setTunEnabled(expected) else {
            let restored = restore(transaction: transaction, originalRuntimeTun: originalRuntime.tunEnabled)
            return failedSnapshot(
                .degraded,
                restored ? "Mihomo 拒绝切换 TUN，已恢复原模式" : "Mihomo 拒绝切换 TUN，且无法确认完整恢复"
            )
        }

        _ = runtime.closeAllConnections()
        var verifiedRuntime = runtime.configuration()
        for attempt in 0..<5 where verifiedRuntime?.tunEnabled != expected {
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.5) }
            verifiedRuntime = runtime.configuration()
        }
        let verifiedPersistent = try? preferenceStore.read()
        let dataPlaneReady = runtime.probeHTTPS() && systemHTTPSProbe.probeHTTPS()
        let verified = verifiedRuntime?.tunEnabled == expected &&
            verifiedPersistent == expected &&
            proxyInspector.isEnabled(expectedPort: verifiedRuntime?.mixedPort ?? originalRuntime.mixedPort) &&
            dataPlaneReady
        guard verified else {
            let restored = restore(transaction: transaction, originalRuntimeTun: originalRuntime.tunEnabled)
            return failedSnapshot(
                .degraded,
                restored ? "模式验证失败，已恢复原 TUN 状态" : "模式验证失败，且无法确认完整恢复"
            )
        }
        do {
            try preferenceStore.commit(transaction)
        } catch {
            let restored = restore(transaction: transaction, originalRuntimeTun: originalRuntime.tunEnabled)
            return failedSnapshot(
                .degraded,
                restored ? "事务提交失败，已恢复原 TUN 状态" : "事务提交失败，且无法确认完整恢复"
            )
        }
        return makeSnapshot(
            runtime: verifiedRuntime,
            persistent: verifiedPersistent,
            proxyEnabled: true,
            dataPlaneReady: true
        )
    }

    private func publishCurrentSnapshot() {
        let runtimeConfiguration = runtime.configuration()
        let persistent = try? preferenceStore.read()
        let snapshot = makeSnapshot(
            runtime: runtimeConfiguration,
            persistent: persistent,
            proxyEnabled: proxyInspector.isEnabled(expectedPort: runtimeConfiguration?.mixedPort ?? 7897),
            dataPlaneReady: runtimeConfiguration != nil && runtime.probeHTTPS() && systemHTTPSProbe.probeHTTPS()
        )
        DispatchQueue.main.async { self.snapshot = snapshot }
    }

    private func restore(
        transaction: VergeTunPreferenceTransaction,
        originalRuntimeTun: Bool
    ) -> Bool {
        var runtimeRestored = runtime.configuration()?.tunEnabled == originalRuntimeTun
        if !runtimeRestored {
            runtimeRestored = runtime.setTunEnabled(originalRuntimeTun)
            _ = runtime.closeAllConnections()
        }
        let persistentRestored: Bool
        do {
            try preferenceStore.rollback(transaction)
            persistentRestored = true
        } catch {
            persistentRestored = false
        }
        return runtimeRestored && persistentRestored
    }

    private func makeSnapshot(
        runtime: MihomoClient.RuntimeConfiguration?,
        persistent: Bool?,
        proxyEnabled: Bool,
        dataPlaneReady: Bool
    ) -> ClashOverlaySnapshot {
        guard let runtime else { return failedSnapshot(.unavailable, "Clash/Mihomo 控制面不可用") }
        let mode: ClashOverlayMode = runtime.tunEnabled ? .tunFull : .systemProxy
        let baseline = Self.baselineReady(runtime)
        let consistent = persistent == runtime.tunEnabled
        let configurationReady = proxyEnabled && consistent && (mode == .systemProxy || baseline)
        let health: ClashOverlayHealth = !configurationReady
            ? .configurationDrift
            : (dataPlaneReady ? .ready : .degraded)
        let reason: String? = !proxyEnabled
            ? "系统代理未开启"
            : (!consistent
                ? "runtime 与 enable_tun_mode 不一致"
                : (mode == .tunFull && !baseline
                    ? "TUN 共存基线不完整"
                    : (dataPlaneReady ? nil : "Clash 或系统 HTTPS 数据面不可用")))
        return .init(
            mode: mode,
            runtimeTunEnabled: runtime.tunEnabled,
            persistentTunEnabled: persistent,
            systemProxyEnabled: proxyEnabled,
            coexistenceBaselineReady: baseline,
            dataPlaneReady: dataPlaneReady,
            health: health,
            reason: reason
        )
    }

    private func failedSnapshot(_ health: ClashOverlayHealth, _ reason: String) -> ClashOverlaySnapshot {
        .init(
            mode: snapshot.mode,
            runtimeTunEnabled: snapshot.runtimeTunEnabled,
            persistentTunEnabled: snapshot.persistentTunEnabled,
            systemProxyEnabled: snapshot.systemProxyEnabled,
            coexistenceBaselineReady: snapshot.coexistenceBaselineReady,
            dataPlaneReady: false,
            health: health,
            reason: reason
        )
    }

    private static func baselineReady(_ runtime: MihomoClient.RuntimeConfiguration) -> Bool {
        !runtime.ipv6Enabled && requiredExclusions.isSubset(of: runtime.routeExclusions)
    }
}
#else
final class ClashOverlayModeController: ObservableObject {
    @Published private(set) var snapshot = ClashOverlaySnapshot(
        mode: nil,
        runtimeTunEnabled: nil,
        persistentTunEnabled: nil,
        systemProxyEnabled: false,
        coexistenceBaselineReady: false,
        dataPlaneReady: false,
        health: .unavailable,
        reason: "App Store Lite 不提供 Clash 模式写入能力"
    )
    @Published private(set) var isSwitching = false

    func refresh() {}
    func switchMode(to _: ClashOverlayMode) {}
}
#endif
