import Combine
import CryptoKit
import Foundation
import NetworkExecution

enum ClashNetworkMode: String, Codable, CaseIterable {
    case companyCoexistence = "company-coexistence"
    case unifiedEgress = "unified-egress"
    case originalNetwork = "original-network"

    var displayName: String {
        switch self {
        case .companyCoexistence: return "公司共存"
        case .unifiedEgress: return "统一出口"
        case .originalNetwork: return "原网络"
        }
    }
}

struct ClashModeManifest: Decodable {
    struct Entry: Decodable, Equatable {
        let id: String
        let profileUID: String
        let profileFile: String
        let displayName: String
        let sourceSHA256: String
        let ruleMarker: String
        let targetGroup: String
        var expectedRulesSHA256: String? = nil
        var scriptFile: String? = nil
        var scriptSHA256: String? = nil
        var expectedIPv6: Bool? = nil
        var expectedDNSSHA256: String? = nil
        var expectedTunPolicy: ClashTunPolicy? = nil
        var expectedTunCaptureKeys: [String]? = nil
        var expectedTunCaptureSHA256: String? = nil
        var expectedUnifiedMembersSHA256: String? = nil
    }
    let activationOwner: String?
    let networkSettingsOwner: String?
    let ipv6Policy: String?
    let schemaVersion: Int
    let configRoot: String
    let modes: [Entry]

    func entry(for mode: ClashNetworkMode) throws -> Entry {
        guard schemaVersion == 2, activationOwner == "clash-native", networkSettingsOwner == "clash-native", ipv6Policy == "capture-and-reject-public", modes.count == 2,
              Set(modes.map(\.id)) == Set([ClashNetworkMode.companyCoexistence.rawValue, ClashNetworkMode.unifiedEgress.rawValue]),
              Set(modes.map(\.profileUID)).count == 2,
              Set(modes.map(\.displayName)).count == 2,
              let entry = modes.first(where: { $0.id == mode.rawValue }),
              !entry.profileUID.isEmpty,
              entry.profileFile == URL(fileURLWithPath: entry.profileFile).lastPathComponent,
              !entry.profileFile.contains(".."), !entry.profileFile.contains("/"),
              entry.profileFile.hasSuffix(".yaml"),
              entry.sourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              entry.ruleMarker.hasPrefix("DOMAIN,netbar-mode-"),
              !entry.targetGroup.isEmpty,
              configRoot.hasPrefix("/") else {
            throw ClashModeFailure("配置登记无效，请由 dual-vpn-config 重新生成双配置")
        }
        return entry
    }
}

struct ClashTunPolicy: Codable, Equatable {
    static let captureKeys = ["auto-route", "auto-detect-interface", "strict-route", "dns-hijack", "disable-icmp-forwarding", "route-address", "route-address-set", "route-exclude-address", "route-exclude-address-set", "inet4-route-address", "inet6-route-address", "inet4-route-exclude-address", "inet6-route-exclude-address", "exclude-ip", "include-interface", "exclude-interface", "include-uid", "include-uid-range", "exclude-uid", "exclude-uid-range", "exclude-src-port", "exclude-src-port-range", "exclude-dst-port", "exclude-dst-port-range", "include-android-user", "include-package", "exclude-package", "include-mac-address", "exclude-mac-address", "file-descriptor"]
    var autoRoute: Bool
    var autoDetectInterface: Bool
    var strictRoute: Bool
    var dnsHijack: [String]
    var routeExcludeAddress: [String]
    enum CodingKeys: String, CodingKey {
        case autoRoute = "auto-route", autoDetectInterface = "auto-detect-interface"
        case strictRoute = "strict-route", dnsHijack = "dns-hijack", routeExcludeAddress = "route-exclude-address"
    }
    func matches(_ other: Self) -> Bool {
        autoRoute == other.autoRoute && autoDetectInterface == other.autoDetectInterface && strictRoute == other.strictRoute &&
        Set(dnsHijack) == Set(other.dnsHijack) && Set(routeExcludeAddress) == Set(other.routeExcludeAddress)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.matches(rhs) }
}

struct ClashModeRuntime: Equatable {
    let profileUID: String
    let tunEnabled: Bool
    let systemProxyEnabled: Bool
    let runtimeRuleMode: Bool
    let markers: Set<String>
    let selectors: [String: String]
    let members: [String: [String]]
    let proxyTypes: [String: String]
    let hijacksUDPAndTCP: Bool
    var ipv6Enabled: Bool
    var routingDigest: String = ""
    var rulesSHA256: String = ""
    var dnsSHA256: String = ""
    var tunPolicy: ClashTunPolicy? = nil
    var tunCaptureSHA256: String = ""
    var disabledRuleCount: Int = 0

    var manualSelectors: [String: String] { selectors.filter { proxyTypes[$0.key] == "Selector" || proxyTypes[$0.key] == nil } }

    func leaf(for group: String) -> String? {
        var cursor = group
        var seen = Set<String>()
        for _ in 0..<20 {
            guard seen.insert(cursor).inserted else { return nil }
            if let next = selectors[cursor] { cursor = next; continue }
            guard let type = proxyTypes[cursor], !["Direct", "Reject", "Pass", "Compatible"].contains(type),
                  members[cursor] == nil else { return nil }
            return cursor
        }
        return nil
    }

    func isRealNodeSelector(_ group: String) -> Bool {
        guard proxyTypes[group] == "Selector", let nodes = members[group], !nodes.isEmpty else { return false }
        return nodes.allSatisfy { node in
            guard let type = proxyTypes[node], members[node] == nil else { return false }
            return !["Direct", "Reject", "Pass", "Compatible", "Selector", "URLTest", "Fallback", "LoadBalance"].contains(type)
        }
    }

    func membersSHA256(_ group: String) -> String? {
        guard let nodes = members[group], let data = try? JSONSerialization.data(withJSONObject: nodes, options: [.withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Read-only identity includes automatic selector leaves as well as manual choices.
    var controlFingerprint: String {
        let choices = selectors.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let topology = (try? JSONSerialization.data(withJSONObject: ["members": members, "types": proxyTypes], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let topologyHash = SHA256.hash(data: topology).map { String(format: "%02x", $0) }.joined()
        return "\(profileUID)|\(tunEnabled)|\(systemProxyEnabled)|\(ipv6Enabled)|\(runtimeRuleMode)|\(routingDigest)|\(choices)|\(topologyHash)"
    }
}

struct ClashModeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ClashNetworkModeSnapshot {
    var mode: ClashNetworkMode?
    var runtime: ClashModeRuntime?
    var phase = "待检测"
    var configurationMatches = false
    var reason: String?
    var networkFingerprint = ""
    var selectedNode: String?
    var evidenceFingerprint: String { [runtime?.controlFingerprint ?? "unknown", networkFingerprint, mode?.rawValue ?? "unknown", String(configurationMatches), selectedNode ?? "unknown", reason ?? ""].joined(separator: "|") }
    var headline: String { mode?.displayName ?? (runtime == nil ? "Clash 状态待检测" : "其他 Clash 配置") }
}

struct ClashNetworkProbe: Equatable {
    let fingerprint: String
    let sampledAt: Date
    let passed: Bool
    let detail: String
    func isFresh(for snapshot: ClashNetworkModeSnapshot, now: Date = Date()) -> Bool {
        snapshot.runtime != nil && fingerprint == snapshot.evidenceFingerprint && now.timeIntervalSince(sampledAt) >= 0 && now.timeIntervalSince(sampledAt) < 300
    }
}

#if !APP_STORE
/// This interface deliberately has no network-configuration mutation operation.
protocol ClashNetworkModeBackend: AnyObject {
    func manifest() throws -> ClashModeManifest
    func runtime() throws -> ClashModeRuntime
    func networkFingerprint() throws -> String
    func assertCompanyVPNDisconnected() throws
    func verifyDNSPath(mode: ClashNetworkMode, entry: ClashModeManifest.Entry, leaf: String) throws
    func verifySystemHTTPS() throws
}

struct ClashModeObserver {
    let backend: ClashNetworkModeBackend
    func observe() -> ClashNetworkModeSnapshot {
        var result = ClashNetworkModeSnapshot()
        do {
            let runtime = try backend.runtime()
            result.runtime = runtime
            result.networkFingerprint = try backend.networkFingerprint()
            let manifest = try backend.manifest()
            result.mode = manifest.modes.first(where: { $0.profileUID == runtime.profileUID }).flatMap { ClashNetworkMode(rawValue: $0.id) }
            if let mode = result.mode {
                let entry = try manifest.entry(for: mode)
                result.selectedNode = runtime.leaf(for: entry.targetGroup)
                result.configurationMatches = runtime.runtimeRuleMode && runtime.disabledRuleCount == 0 &&
                    runtime.markers.contains(entry.ruleMarker) && runtime.rulesSHA256 == entry.expectedRulesSHA256 &&
                    runtime.dnsSHA256 == entry.expectedDNSSHA256 && runtime.ipv6Enabled == true &&
                    runtime.tunPolicy == entry.expectedTunPolicy && runtime.tunCaptureSHA256 == entry.expectedTunCaptureSHA256 &&
                    (mode != .unifiedEgress || (runtime.isRealNodeSelector(entry.targetGroup) && runtime.membersSHA256(entry.targetGroup) == entry.expectedUnifiedMembersSHA256))
                if !result.configurationMatches { result.reason = "运行策略与登记不一致；请在 Clash 原生重新激活并检查共同设置。" }
                if mode == .unifiedEgress {
                    do { try backend.assertCompanyVPNDisconnected() }
                    catch { result.reason = "统一保障条件未满足：" + error.localizedDescription }
                }
            }
            if !runtime.tunEnabled && !runtime.systemProxyEnabled { result.phase = "流量接管已关闭 · DNS 需独立核对" }
            else { result.phase = "已读取现状 · Clash 原生管理" }
        } catch { result.reason = error.localizedDescription }
        return result
    }

    func probe(_ snapshot: ClashNetworkModeSnapshot, now: Date = Date()) -> ClashNetworkProbe {
        do {
            guard snapshot.configurationMatches, snapshot.runtime?.tunEnabled == true,
                  snapshot.runtime?.systemProxyEnabled == true, let mode = snapshot.mode, let leaf = snapshot.selectedNode else {
                throw ClashModeFailure("配置、TUN、系统代理或真实节点条件未满足；请在 Clash 中检查。")
            }
            if mode == .unifiedEgress { try backend.assertCompanyVPNDisconnected() }
            let entry = try backend.manifest().entry(for: mode)
            try backend.verifyDNSPath(mode: mode, entry: entry, leaf: leaf)
            try backend.verifySystemHTTPS()
            let after = observe()
            guard after.evidenceFingerprint == snapshot.evidenceFingerprint, after.configurationMatches else {
                throw ClashModeFailure("检测期间配置、节点或网络变化，结果已失效。")
            }
            return .init(fingerprint: snapshot.evidenceFingerprint, sampledAt: now, passed: true,
                         detail: "本轮 UDP/TCP DNS 经 Cloudflare DoH 与所选节点；系统解析及 HTTPS 可达。IPv6/业务需独立验收。")
        } catch {
            return .init(fingerprint: snapshot.evidenceFingerprint, sampledAt: now, passed: false, detail: error.localizedDescription)
        }
    }
}
#endif

final class ClashNetworkModeController: ObservableObject {
    @Published private(set) var snapshot = ClashNetworkModeSnapshot()
    @Published private(set) var probe: ClashNetworkProbe?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isProbing = false
    private var revision: UInt64 = 0
    private let queue = DispatchQueue(label: "com.zjah.NetBar.clash-observation", qos: .utility)
    #if !APP_STORE
    private let backend: ClashNetworkModeBackend
    init(backend: ClashNetworkModeBackend = LiveClashNetworkModeBackend()) { self.backend = backend }
    #else
    init() {}
    #endif

    func invalidateProbe() {
        revision &+= 1
        probe = nil
    }

    func refresh() { read(probing: false) }
    func detectCurrentNetwork() { read(probing: true) }
    private func read(probing: Bool) {
        #if !APP_STORE
        guard !isRefreshing, !isProbing else { return }
        isRefreshing = !probing; isProbing = probing
        let currentRevision = revision
        queue.async { [weak self] in
            guard let self else { return }
            let observer = ClashModeObserver(backend: self.backend)
            let result = observer.observe()
            let evidence = probing ? observer.probe(result) : nil
            DispatchQueue.main.async {
                self.isRefreshing = false; self.isProbing = false
                guard currentRevision == self.revision else { return }
                if result.evidenceFingerprint != self.snapshot.evidenceFingerprint { self.probe = nil }
                self.snapshot = result
                if let evidence { self.probe = evidence }
            }
        }
        #else
        snapshot.reason = "App Store Lite 不提供 Clash 本机控制端诊断；请打开 Clash 查看。"
        #endif
    }

    var freshProbe: ClashNetworkProbe? { guard !isRefreshing, !isProbing else { return nil }; return probe.flatMap { $0.isFresh(for: snapshot) ? $0 : nil } }
    var overlaySummary: ClashOverlaySnapshot {
        let runtime = snapshot.runtime
        return .init(mode: runtime.map { $0.tunEnabled ? .tunFull : .systemProxy }, runtimeTunEnabled: runtime?.tunEnabled,
                     persistentTunEnabled: runtime?.tunEnabled, systemProxyEnabled: runtime?.systemProxyEnabled ?? false,
                     coexistenceBaselineReady: snapshot.configurationMatches,
                     dataPlaneReady: freshProbe?.passed == true,
                     health: freshProbe?.passed == true ? .ready : .degraded, reason: snapshot.reason)
    }
}
