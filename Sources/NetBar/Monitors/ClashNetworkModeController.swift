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
    let schemaVersion: Int
    let configRoot: String
    let modes: [Entry]

    func entry(for mode: ClashNetworkMode) throws -> Entry {
        guard schemaVersion == 1, modes.count == 2,
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
    static let captureKeys = ["auto-route", "auto-detect-interface", "strict-route", "dns-hijack", "route-address", "route-address-set", "route-exclude-address", "route-exclude-address-set", "inet4-route-address", "inet6-route-address", "inet4-route-exclude-address", "inet6-route-exclude-address", "exclude-ip", "include-interface", "exclude-interface", "include-uid", "include-uid-range", "exclude-uid", "exclude-uid-range", "exclude-src-port", "exclude-src-port-range", "exclude-dst-port", "exclude-dst-port-range", "include-android-user", "include-package", "exclude-package", "include-mac-address", "exclude-mac-address", "file-descriptor"]
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
    let ipv6Enabled: Bool
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

    /// Only fields this transaction can change. Unrelated preferences stay owned by Clash.
    var controlFingerprint: String {
        let choices = manualSelectors.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let topology = (try? JSONSerialization.data(withJSONObject: ["members": members, "types": proxyTypes], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let topologyHash = SHA256.hash(data: topology).map { String(format: "%02x", $0) }.joined()
        return "\(profileUID)|\(tunEnabled)|\(systemProxyEnabled)|\(runtimeRuleMode)|\(routingDigest)|\(choices)|\(topologyHash)"
    }
}

struct ClashDNSLeaseStatus: Decodable, Equatable {
    let protocolVersion: Int
    let dnsLeaseState: String
    let dnsLeaseOwnerPID: Int?
    let dnsLeaseServices: Int
    let reason: String?
    static let unavailable = Self(protocolVersion: 0, dnsLeaseState: "unknown", dnsLeaseOwnerPID: nil, dnsLeaseServices: 0, reason: "DNS 恢复组件未就绪")
    var ownedByThisProcess: Bool { dnsLeaseState == "owned" && dnsLeaseOwnerPID == Int(ProcessInfo.processInfo.processIdentifier) }
    var managedByThisProcess: Bool { ["preparing", "owned", "conflict"].contains(dnsLeaseState) && dnsLeaseOwnerPID == Int(ProcessInfo.processInfo.processIdentifier) }
    var displayName: String {
        switch dnsLeaseState {
        case "owned": return ownedByThisProcess ? "已接管 · \(dnsLeaseServices) 个服务" : "其他进程持有，待恢复"
        case "inactive": return "未接管"
        case "preparing": return "已保存原 DNS · 等待核验"
        case "conflict": return "外部修改，待处理"
        default: return "组件未就绪"
        }
    }
}

struct ClashNetworkModeSnapshot {
    var mode: ClashNetworkMode?
    var runtime: ClashModeRuntime?
    var dns: ClashDNSLeaseStatus = .unavailable
    var phase = "待检测"
    var verified = false
    var reason: String?
    var manualPending = false

    var headline: String {
        guard let mode else { return runtime == nil ? "Clash 状态待检测" : "其他 Clash 配置" }
        if dns.ownedByThisProcess, runtime?.tunEnabled != true || runtime?.systemProxyEnabled != true { return "DNS 仍接管，流量接管不完整" }
        if mode == .unifiedEgress, !dns.ownedByThisProcess { return "统一配置仍运行，DNS 未接管" }
        return mode.displayName
    }
}

struct ClashModeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

#if !APP_STORE
protocol ClashNetworkModeBackend: AnyObject {
    func manifest() throws -> ClashModeManifest
    func runtime() throws -> ClashModeRuntime
    func dnsStatus() throws -> ClashDNSLeaseStatus
    func assertCompanyVPNDisconnected() throws
    func activate(_ entry: ClashModeManifest.Entry) throws
    func restoreProfile(_ uid: String) throws
    func setNativeTunPolicy(_ policy: ClashTunPolicy) throws
    func setNativeSwitch(tun: Bool, proxy: Bool) throws
    func select(group: String, node: String) throws
    func prepareDNS() throws
    func acquireDNS() throws
    func releaseDNS() throws
    func verifyDNSPath(mode: ClashNetworkMode, entry: ClashModeManifest.Entry, leaf: String) throws
    func verifySystemHTTPS() throws
    func closeConnections() throws
}

/// Synchronous engine runs on a private serial queue. Startup/readback never acquires DNS.
final class ClashModeTransactionEngine {
    let backend: ClashNetworkModeBackend
    private let interrupted: () -> Bool
    init(backend: ClashNetworkModeBackend, interrupted: @escaping () -> Bool = { false }) {
        self.backend = backend; self.interrupted = interrupted
    }

    func observe() -> ClashNetworkModeSnapshot {
        var result = ClashNetworkModeSnapshot()
        do {
            let runtime = try backend.runtime()
            result.runtime = runtime
            let manifest = try? backend.manifest()
            result.mode = manifest?.modes.first(where: { $0.profileUID == runtime.profileUID }).flatMap { ClashNetworkMode(rawValue: $0.id) }
            result.dns = (try? backend.dnsStatus()) ?? .unavailable
            if !runtime.tunEnabled && !runtime.systemProxyEnabled && result.dns.dnsLeaseState == "inactive" { result.mode = .originalNetwork }
            result.phase = "已读取现状"
            // Protection is verified by a switch, not by a persisted intention or a menu click.
            result.reason = result.dns.reason
            if result.dns.ownedByThisProcess && (!runtime.tunEnabled || !runtime.hijacksUDPAndTCP) {
                result.reason = "DNS 仍被本次接管，但 TUN 或双协议劫持已关闭。恢复组件将释放 DNS；也可选择“原网络”。"
                result.manualPending = true
            } else if result.mode == .unifiedEgress && !result.dns.ownedByThisProcess {
                result.reason = "Clash 仍在使用统一配置；DNS 保障已解除。选择模式后才会重新接管。"
            }
        } catch { result.reason = error.localizedDescription }
        return result
    }

    func apply(_ mode: ClashNetworkMode) -> ClashNetworkModeSnapshot {
        var stage = "预检"
        var baseline: ClashModeRuntime?
        var ownedState: ClashModeRuntime?
        var hadDNS = false
        var acquiredDNS = false
        var releasedDNS = false
        do {
            try checkInterruption()
            let original = try backend.runtime(); baseline = original; ownedState = original
            let originalDNS = try backend.dnsStatus()
            guard originalDNS.protocolVersion >= 7,
                  originalDNS.dnsLeaseState == "inactive" || originalDNS.ownedByThisProcess || (mode == .originalNetwork && originalDNS.dnsLeaseState == "conflict") else {
                throw ClashModeFailure(originalDNS.reason ?? "DNS 被其他任务持有或发生外部修改，请先处理")
            }
            hadDNS = originalDNS.ownedByThisProcess
            if mode == .originalNetwork {
                stage = "恢复 DNS"
                try backend.releaseDNS(); releasedDNS = hadDNS
                try checkInterruption()
                try assertUnchanged(original)
                stage = "关闭流量接管"
                do { try backend.setNativeSwitch(tun: false, proxy: false) }
                catch {
                    if let observed = try? backend.runtime(), observed.profileUID == original.profileUID,
                       observed.routingDigest == original.routingDigest, observed.manualSelectors == original.manualSelectors,
                       (observed.tunEnabled == original.tunEnabled || !observed.tunEnabled),
                       (observed.systemProxyEnabled == original.systemProxyEnabled || !observed.systemProxyEnabled) { ownedState = observed }
                    throw error
                }
                let current = try backend.runtime(); ownedState = current
                guard current.profileUID == original.profileUID, !current.tunEnabled, !current.systemProxyEnabled,
                      current.manualSelectors == original.manualSelectors else { throw ClashModeFailure("原网络状态核验失败") }
                let dns = try backend.dnsStatus()
                guard dns.dnsLeaseState == "inactive" else { throw ClashModeFailure("DNS 恢复尚未完成") }
                try backend.closeConnections()
                return try verifiedSnapshot(expected: current, mode: mode, entry: nil)
            }
            let manifest = try backend.manifest()
            let entry = try manifest.entry(for: mode)
            if mode == .unifiedEgress { try backend.assertCompanyVPNDisconnected() }
            let preferredLeaf = mode == .unifiedEgress
                ? (original.leaf(for: "🌐 统一出口") ?? original.leaf(for: "♻️ 手动切换")) : nil
            if mode == .unifiedEgress, preferredLeaf == nil { throw ClashModeFailure("未找到当前手动选择的真实代理节点") }
            try assertUnchanged(original)
            stage = "保存 DNS 原件"
            acquiredDNS = true // Preparation is a recoverable journal, without a DNS write.
            try backend.prepareDNS()
            try checkInterruption()
            try assertUnchanged(original)
            stage = "原生激活配置"
            try checkInterruption()
            if original.profileUID != entry.profileUID || original.rulesSHA256 != entry.expectedRulesSHA256 || !original.markers.contains(entry.ruleMarker) || original.dnsSHA256 != entry.expectedDNSSHA256 || original.ipv6Enabled != entry.expectedIPv6 || original.tunCaptureSHA256 != entry.expectedTunCaptureSHA256 {
                do { try backend.activate(entry) }
                catch {
                    if let observed = try? backend.runtime(), observed.profileUID == entry.profileUID,
                       observed.rulesSHA256 == entry.expectedRulesSHA256, observed.markers.contains(entry.ruleMarker),
                       observed.tunEnabled == original.tunEnabled, observed.systemProxyEnabled == original.systemProxyEnabled {
                        ownedState = observed
                    }
                    throw error
                }
            }
            var active = try backend.runtime(); ownedState = active
            guard active.profileUID == entry.profileUID, active.markers.contains(entry.ruleMarker), active.runtimeRuleMode, active.disabledRuleCount == 0,
                  entry.expectedRulesSHA256 != nil, active.rulesSHA256 == entry.expectedRulesSHA256 else {
                throw ClashModeFailure("配置 UID 与实际运行规则不一致")
            }
            if mode == .unifiedEgress, !active.isRealNodeSelector(entry.targetGroup) || entry.expectedUnifiedMembersSHA256 == nil || active.membersSHA256(entry.targetGroup) != entry.expectedUnifiedMembersSHA256 {
                throw ClashModeFailure("统一出口必须是只包含真实节点的手动选择组；拒绝自动或直连回退")
            }
            if let leaf = preferredLeaf {
                guard active.members[entry.targetGroup]?.contains(leaf) == true else { throw ClashModeFailure("当前节点已不在统一配置中，请重新选择可用节点") }
                stage = "对齐出口节点"
                try checkInterruption()
                do { try backend.select(group: entry.targetGroup, node: leaf) }
                catch {
                    if let observed = try? backend.runtime(), observed.profileUID == active.profileUID,
                       observed.routingDigest == active.routingDigest, observed.tunEnabled == active.tunEnabled,
                       observed.systemProxyEnabled == active.systemProxyEnabled,
                       observed.manualSelectors == active.manualSelectors.merging([entry.targetGroup: leaf], uniquingKeysWith: { _, new in new }) {
                        ownedState = observed
                    }
                    throw error
                }
                active = try backend.runtime(); ownedState = active
                guard active.leaf(for: entry.targetGroup) == leaf else { throw ClashModeFailure("统一节点选择未生效") }
            }
            guard let leaf = active.leaf(for: entry.targetGroup) else { throw ClashModeFailure("目标组未选择真实代理节点") }
            try assertUnchanged(active)
            stage = "对齐原生 TUN 策略"
            try checkInterruption()
            guard let tunPolicy = entry.expectedTunPolicy, entry.expectedIPv6 != nil, entry.expectedDNSSHA256 != nil,
                  entry.expectedTunCaptureSHA256 != nil, entry.expectedTunCaptureKeys?.isEmpty == false else { throw ClashModeFailure("模式策略契约不完整，请重新生成双配置") }
            if active.tunPolicy?.matches(tunPolicy) != true {
                do { try backend.setNativeTunPolicy(tunPolicy) }
                catch {
                    if let observed = try? backend.runtime(), observed.profileUID == active.profileUID,
                       observed.rulesSHA256 == active.rulesSHA256, observed.manualSelectors == active.manualSelectors,
                       observed.tunEnabled == active.tunEnabled, observed.systemProxyEnabled == active.systemProxyEnabled,
                       observed.tunPolicy?.matches(tunPolicy) == true { ownedState = observed }
                    throw error
                }
            }
            active = try backend.runtime(); ownedState = active
            guard active.tunPolicy?.matches(tunPolicy) == true else { throw ClashModeFailure("原生 TUN 策略未生效") }
            stage = "开启流量接管"
            try checkInterruption()
            do { try backend.setNativeSwitch(tun: true, proxy: true) }
            catch {
                if let observed = try? backend.runtime(), observed.profileUID == active.profileUID,
                   observed.routingDigest == active.routingDigest, observed.manualSelectors == active.manualSelectors,
                   (observed.tunEnabled == active.tunEnabled || observed.tunEnabled),
                   (observed.systemProxyEnabled == active.systemProxyEnabled || observed.systemProxyEnabled) { ownedState = observed }
                throw error
            }
            active = try backend.runtime(); ownedState = active
            guard active.profileUID == entry.profileUID, active.tunEnabled, active.systemProxyEnabled,
                  active.markers.contains(entry.ruleMarker), active.rulesSHA256 == entry.expectedRulesSHA256, active.hijacksUDPAndTCP,
                  active.leaf(for: entry.targetGroup) == leaf,
                  active.ipv6Enabled == entry.expectedIPv6, active.dnsSHA256 == entry.expectedDNSSHA256,
                  active.tunPolicy?.matches(tunPolicy) == true, active.tunCaptureSHA256 == entry.expectedTunCaptureSHA256 else { throw ClashModeFailure("TUN、代理、双协议 DNS 劫持或 IPv6 配置未生效，或存在额外绕过字段") }
            if mode == .unifiedEgress, !active.isRealNodeSelector(entry.targetGroup) || active.membersSHA256(entry.targetGroup) != entry.expectedUnifiedMembersSHA256 { throw ClashModeFailure("统一出口组在切换期间变化") }
            stage = "核验 DNS 劫持"
            try backend.verifyDNSPath(mode: mode, entry: entry, leaf: leaf)
            try checkInterruption()
            try assertUnchanged(active)
            stage = "临时接管 DNS"
            acquiredDNS = true // Includes ambiguous/partial acquisition failures.
            try backend.acquireDNS()
            try checkInterruption()
            let dns = try backend.dnsStatus()
            guard dns.ownedByThisProcess else { throw ClashModeFailure("DNS 接管未核验，保留待处理") }
            stage = "核验系统网络"
            try backend.verifySystemHTTPS()
            try backend.verifyDNSPath(mode: mode, entry: entry, leaf: leaf)
            try assertUnchanged(active)
            try backend.closeConnections()
            return try verifiedSnapshot(expected: active, mode: mode, entry: entry)
        } catch {
            // Process exit strictly releases DNS. Never undo a profile or switch on this path.
            if interrupted() {
                try? backend.releaseDNS()
                var result = observe(); result.phase = "已停止切换"; result.reason = "退出期间只恢复 DNS；Clash 保持实际状态。"
                return result
            }
            var restored = true
            if let baseline, let ownedState {
                do {
                    let current = try backend.runtime()
                    // A native operation may have completed despite an error. Only accept the
                    // last observed state or our original baseline; never overwrite a third state.
                    guard current.controlFingerprint == ownedState.controlFingerprint || current.controlFingerprint == baseline.controlFingerprint else {
                        throw ClashModeFailure("外部并发修改，停止覆盖式回滚")
                    }
                    if releasedDNS && hadDNS {
                        guard try backend.dnsStatus().dnsLeaseState == "inactive" else { throw ClashModeFailure("DNS 存在外部修改，停止重新接管") }
                        // Capture restored originals before a rollback can enable TUN again.
                        try backend.prepareDNS()
                    }
                    if current.controlFingerprint != baseline.controlFingerprint {
                        var rollbackOwned = current
                        if current.profileUID != baseline.profileUID {
                            try assertUnchanged(rollbackOwned)
                            try backend.restoreProfile(baseline.profileUID)
                            let after = try backend.runtime()
                            guard after.profileUID == baseline.profileUID, after.manualSelectors == baseline.manualSelectors,
                                  after.members == baseline.members, after.proxyTypes == baseline.proxyTypes,
                                  after.tunEnabled == rollbackOwned.tunEnabled, after.systemProxyEnabled == rollbackOwned.systemProxyEnabled,
                                  after.rulesSHA256 == baseline.rulesSHA256, after.dnsSHA256 == baseline.dnsSHA256,
                                  after.ipv6Enabled == baseline.ipv6Enabled, after.tunPolicy == rollbackOwned.tunPolicy else {
                                throw ClashModeFailure("原生恢复后的节点或控制状态与已保存基线不一致，停止继续覆盖")
                            }
                            rollbackOwned = after
                        }
                        if let policy = baseline.tunPolicy, rollbackOwned.tunPolicy?.matches(policy) != true {
                            try assertUnchanged(rollbackOwned)
                            try backend.setNativeTunPolicy(policy)
                            let after = try backend.runtime()
                            guard after.profileUID == baseline.profileUID, after.manualSelectors == rollbackOwned.manualSelectors,
                                  after.members == rollbackOwned.members, after.proxyTypes == rollbackOwned.proxyTypes,
                                  after.tunEnabled == rollbackOwned.tunEnabled, after.systemProxyEnabled == rollbackOwned.systemProxyEnabled,
                                  after.routingDigest == baseline.routingDigest else { throw ClashModeFailure("TUN 恢复期间发生外部修改") }
                            rollbackOwned = after
                        }
                        try assertUnchanged(rollbackOwned)
                        try backend.setNativeSwitch(tun: baseline.tunEnabled, proxy: baseline.systemProxyEnabled)
                        guard try backend.runtime().controlFingerprint == baseline.controlFingerprint else { throw ClashModeFailure("原 Clash 状态未完整恢复") }
                    }
                    if hadDNS && (releasedDNS || acquiredDNS) {
                        let dns = try backend.dnsStatus()
                        guard dns.managedByThisProcess else { throw ClashModeFailure("原 DNS 原件不再由本次事务持有，停止重新接管") }
                        if !dns.ownedByThisProcess { try backend.acquireDNS() }
                    } else if !hadDNS && acquiredDNS {
                        let dns = try backend.dnsStatus()
                        if dns.managedByThisProcess { try backend.releaseDNS() }
                        else if dns.dnsLeaseState != "inactive" { throw ClashModeFailure("DNS 存在外部修改，停止覆盖式恢复") }
                    }
                } catch {
                    restored = false
                    // A failed/untrusted native rollback must not leave DNS owned on an
                    // unverified path. CAS release preserves all external DNS changes.
                    if (try? backend.dnsStatus().managedByThisProcess) == true { try? backend.releaseDNS() }
                }
            }
            let finalDNS = try? backend.dnsStatus()
            if hadDNS { restored = restored && finalDNS?.ownedByThisProcess == true }
            else { restored = restored && finalDNS?.dnsLeaseState == "inactive" }
            var result = observe()
            result.phase = "\(stage)失败"
            result.reason = "\(error.localizedDescription)；\(restored ? "本次已确认的修改已恢复" : "manual_pending：无法证明安全恢复，请检查 Clash 与 DNS 状态")"
            result.manualPending = !restored
            return result
        }
    }

    private func checkInterruption() throws { if interrupted() { throw ClashModeFailure("切换已取消") } }
    private func verifiedSnapshot(expected: ClashModeRuntime, mode: ClashNetworkMode, entry: ClashModeManifest.Entry?) throws -> ClashNetworkModeSnapshot {
        let current = try backend.runtime()
        guard current.controlFingerprint == expected.controlFingerprint else { throw ClashModeFailure("最终回读时 Clash 状态已变化") }
        if let entry { guard try backend.manifest().entry(for: mode) == entry else { throw ClashModeFailure("最终回读时模式登记已变化") } }
        let dns = try backend.dnsStatus()
        guard mode == .originalNetwork ? dns.dnsLeaseState == "inactive" : dns.ownedByThisProcess else { throw ClashModeFailure("最终回读时 DNS 已释放或存在冲突") }
        return .init(mode: mode, runtime: current, dns: dns, phase: mode == .originalNetwork ? "原网络已恢复" : "切换已核验", verified: true)
    }
    private func assertUnchanged(_ expected: ClashModeRuntime) throws {
        guard try backend.runtime().controlFingerprint == expected.controlFingerprint else { throw ClashModeFailure("配置被外部修改，停止切换") }
    }
}
#endif

final class ClashNetworkModeController: ObservableObject {
    @Published private(set) var snapshot = ClashNetworkModeSnapshot()
    @Published private(set) var isSwitching = false
    @Published private(set) var isRefreshing = false
    private var generation: UInt64 = 0
    private let queue = DispatchQueue(label: "com.zjah.NetBar.clash-network-mode", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stopping = false
    #if !APP_STORE
    private let backend: ClashNetworkModeBackend
    init(backend: ClashNetworkModeBackend = LiveClashNetworkModeBackend()) { self.backend = backend }
    #else
    init() {}
    #endif

    func refresh() {
        #if !APP_STORE
        guard !isSwitching, !isRefreshing, !isStopping else { return }
        isRefreshing = true; generation &+= 1; let id = generation
        queue.async { [weak self] in
            guard let self else { return }
            let result = ClashModeTransactionEngine(backend: self.backend).observe()
            DispatchQueue.main.async {
                self.isRefreshing = false
                guard self.generation == id, !self.isStopping else { return }
                self.snapshot = result
            }
        }
        #else
        snapshot.reason = "App Store Lite 不提供配置和 DNS 写入能力"
        #endif
    }

    func switchMode(to mode: ClashNetworkMode) {
        #if !APP_STORE
        guard !isSwitching, !isRefreshing, !isStopping, DistributionFlavor.current.supportsClashModeSwitch else { return }
        isSwitching = true; generation &+= 1; let id = generation
        snapshot.phase = "正在切换"; snapshot.verified = false; snapshot.reason = nil
        queue.async { [weak self] in
            guard let self else { return }
            let result = ClashModeTransactionEngine(backend: self.backend, interrupted: { self.isStopping }).apply(mode)
            DispatchQueue.main.async {
                guard self.generation == id else { return }
                self.isSwitching = false
                self.snapshot = result
            }
        }
        #endif
    }

    /// Called only for application termination. It intentionally has no Clash mutation.
    func releaseDNSForTermination(completion: @escaping () -> Void) {
        stateLock.lock(); stopping = true; stateLock.unlock()
        generation &+= 1
        #if !APP_STORE
        queue.async { [weak self] in
            try? self?.backend.releaseDNS()
            DispatchQueue.main.async(execute: completion)
        }
        #else
        completion()
        #endif
    }

    func installDNSRecoveryComponent() {
        #if !APP_STORE
        let result = LiveRouteSafetyController().openInstaller()
        if !result.succeeded { snapshot.reason = "无法打开恢复组件安装器：\(result.standardError)" }
        #endif
    }

    private var isStopping: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopping }

    var overlaySummary: ClashOverlaySnapshot {
        let runtime = snapshot.runtime
        return .init(mode: runtime.map { $0.tunEnabled ? .tunFull : .systemProxy }, runtimeTunEnabled: runtime?.tunEnabled,
                     persistentTunEnabled: runtime?.tunEnabled, systemProxyEnabled: runtime?.systemProxyEnabled ?? false,
                     coexistenceBaselineReady: snapshot.mode == .companyCoexistence || snapshot.mode == .unifiedEgress,
                     dataPlaneReady: snapshot.verified,
                     health: isSwitching ? .switching : (snapshot.verified ? .ready : .degraded), reason: snapshot.reason)
    }
}
