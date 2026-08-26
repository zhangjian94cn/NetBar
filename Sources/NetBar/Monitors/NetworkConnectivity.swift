import CoreLocation
import CoreWLAN
import CryptoKit
import Foundation
import SystemConfiguration

enum NetworkAccessCandidateKind: String, Codable, Equatable {
    case macMini
    case wifi
}

enum NetworkCandidateState: String, Codable, Equatable {
    case unavailable
    case connecting
    case localOnly
    case internetReady
    case proxyDegraded
    case captivePortal
    case authorizationRequired

    var displayName: String {
        switch self {
        case .unavailable: return "不可用"
        case .connecting: return "正在连接"
        case .localOnly: return "仅局域网"
        case .internetReady: return "可上网"
        case .proxyDegraded: return "Clash/TUN 未收敛"
        case .captivePortal: return "需要网页登录"
        case .authorizationRequired: return "需要手动连接"
        }
    }
}

struct NetworkAccessCandidate: Identifiable, Codable, Equatable {
    let id: String
    let kind: NetworkAccessCandidateKind
    let displayName: String
    let interfaceName: String
    var state: NetworkCandidateState
    var signalStrength: Int?
    var isPinned: Bool
    var isCurrent: Bool
}

struct ConnectivityProbeResult: Equatable {
    let interfaceName: String
    let carrierActive: Bool
    let ipv4Address: String?
    let gateway: String?
    let directHTTPSReachable: Bool
    let clashControllerReachable: Bool
    let clashHTTPSReachable: Bool
    let systemHTTPSReachable: Bool
    let physicalDefaultInterface: String?

    var hasLocalNetwork: Bool {
        carrierActive && ipv4Address != nil && gateway != nil
    }

    var directInternetReady: Bool {
        hasLocalNetwork && directHTTPSReachable
    }

    var completeInternetReady: Bool {
        guard directInternetReady else { return false }
        if clashControllerReachable {
            return clashHTTPSReachable && systemHTTPSReachable
        }
        return systemHTTPSReachable
    }

    /// The user-visible data plane can be healthy on managed networks that block
    /// direct HTTPS but require an already-running proxy/TUN path.
    var routedInternetReady: Bool {
        guard hasLocalNetwork, systemHTTPSReachable else { return false }
        if clashControllerReachable { return clashHTTPSReachable }
        return directHTTPSReachable
    }
}

enum NetworkFailoverPhase: String, Codable, Equatable {
    case miniActive
    case temporaryWiFi
    case stableWiFiFallback
    case miniStabilizing
    case routeFlapping
    case manualWiFi

    var displayName: String {
        switch self {
        case .miniActive: return "Mac mini 正常"
        case .temporaryWiFi: return "Wi-Fi 临时保网"
        case .stableWiFiFallback: return "Wi-Fi 稳定降级"
        case .miniStabilizing: return "Mac mini 恢复确认中"
        case .routeFlapping: return "Mac mini 上游反复抖动"
        case .manualWiFi: return "固定使用 Wi-Fi"
        }
    }
}

enum WiFiLocationAccessState: String, Equatable {
    case notDetermined
    case allowed
    case denied
    case restricted

    var displayName: String {
        switch self {
        case .notDetermined: return "需要定位权限以扫描附近网络"
        case .allowed: return "可扫描附近网络"
        case .denied: return "定位权限未授予，仅使用当前 Wi-Fi"
        case .restricted: return "定位权限受系统限制"
        }
    }
}

struct WiFiCandidateSnapshot: Equatable {
    let candidates: [NetworkAccessCandidate]
    let currentSSID: String?
    let savedSSIDs: Set<String>
    let visibleSSIDs: Set<String>
    let locationAccess: WiFiLocationAccessState
}

enum WiFiAssociationResult: Equatable {
    case connected
    case unavailable
    case authorizationRequired
    case failed(String)
}

protocol WiFiCandidateControlling: AnyObject {
    func snapshot(pinnedSSIDs: [String]) -> WiFiCandidateSnapshot
    func associate(ssid: String) -> WiFiAssociationResult
    func requestLocationAccess()
    func startMonitoring(onChange: @escaping () -> Void)
    func stopMonitoring()
}

struct WiFiCandidateSelector {
    static let anonymousCurrentID = "wifi-current-associated"

    static func select(
        pinnedSSIDs: [String],
        savedSSIDs: Set<String>,
        visibleSignals: [String: Int],
        securedSSIDs: Set<String>? = nil,
        currentSSID: String?,
        locationAccess: WiFiLocationAccessState
    ) -> [NetworkAccessCandidate] {
        let allowedVisible: Set<String>
        if locationAccess == .allowed {
            var visible = Set(visibleSignals.keys).intersection(savedSSIDs)
            if let securedSSIDs { visible.formIntersection(securedSSIDs) }
            allowedVisible = visible
        } else if let currentSSID,
                  savedSSIDs.contains(currentSSID),
                  securedSSIDs?.contains(currentSSID) != false {
            allowedVisible = [currentSSID]
        } else {
            allowedVisible = []
        }

        let orderedPinned = pinnedSSIDs.filter { savedSSIDs.contains($0) }
        let displayOrder = orderedPinned + allowedVisible
            .filter { !orderedPinned.contains($0) }
            .sorted()

        return displayOrder.map { ssid in
            NetworkAccessCandidate(
                id: candidateID(for: ssid),
                kind: .wifi,
                displayName: ssid,
                interfaceName: "en0",
                state: allowedVisible.contains(ssid) ? .localOnly : .unavailable,
                signalStrength: visibleSignals[ssid],
                isPinned: orderedPinned.contains(ssid),
                isCurrent: ssid == currentSSID
            )
        }
    }

    static func bestUsableCandidate(
        from candidates: [NetworkAccessCandidate]
    ) -> NetworkAccessCandidate? {
        candidates.first(where: { $0.isPinned && $0.isCurrent && $0.state != .unavailable })
            ?? candidates.first(where: { $0.isPinned && $0.state != .unavailable })
    }

    static func candidateID(for ssid: String) -> String {
        let digest = SHA256.hash(data: Data(ssid.utf8))
        return "wifi-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func anonymousCurrentCandidate() -> NetworkAccessCandidate {
        NetworkAccessCandidate(
            id: anonymousCurrentID,
            kind: .wifi,
            displayName: "当前已连接 Wi-Fi",
            interfaceName: "en0",
            state: .localOnly,
            signalStrength: nil,
            isPinned: true,
            isCurrent: true
        )
    }
}

final class WiFiCandidatePreferenceStore {
    private let defaults: UserDefaults
    private let key = "networkWiFiCandidateWhitelist"
    private let configuredKey = "networkWiFiCandidateWhitelistConfigured"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isConfigured: Bool { defaults.bool(forKey: configuredKey) }

    func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func save(_ ssids: [String]) {
        var seen = Set<String>()
        let unique = ssids.filter { !$0.isEmpty && seen.insert($0).inserted }
        defaults.set(unique, forKey: key)
        defaults.set(true, forKey: configuredKey)
    }
}

protocol ConnectivityProbing {
    func probe(interfaceName: String) -> ConnectivityProbeResult
}

protocol MihomoRouteRecovering {
    func isControllerAvailable() -> Bool
    func probeHTTPS() -> Bool
    func closeAllConnections() -> Bool
}

final class LiveMihomoRouteRecovery: MihomoRouteRecovering {
    func isControllerAvailable() -> Bool { MihomoClient.runtimeConfiguration() != nil }
    func probeHTTPS() -> Bool { MihomoClient.probeHTTPS() }
    func closeAllConnections() -> Bool {
        #if APP_STORE
        return false
        #else
        return MihomoClient.closeAllConnections()
        #endif
    }
}

final class LiveConnectivityProber: ConnectivityProbing {
    private let runner: NetworkModeCommandRunning
    private let mihomo: MihomoRouteRecovering
    private let directTargets = [
        "https://www.apple.com/library/test/success.html",
        "https://cp.cloudflare.com/generate_204"
    ]

    init(
        runner: NetworkModeCommandRunning = DefaultNetworkModeCommandRunner(),
        mihomo: MihomoRouteRecovering = LiveMihomoRouteRecovery()
    ) {
        self.runner = runner
        self.mihomo = mihomo
    }

    func probe(interfaceName: String) -> ConnectivityProbeResult {
        let interfaceResult = runner.run(executable: "/sbin/ifconfig", arguments: [interfaceName])
        let carrier = interfaceResult.succeeded && LiveNetworkModeSystemProvider.parseInterfaceActive(interfaceResult.standardOutput)
        let ipv4 = interfaceResult.succeeded
            ? LiveNetworkModeSystemProvider.parseInterfaceIPv4s(interfaceResult.standardOutput)
                .first(where: { !$0.hasPrefix("169.254.") })
            : nil
        let route = runner.run(executable: "/sbin/route", arguments: ["-n", "get", "-ifscope", interfaceName, "default"])
        let gateway = route.succeeded
            ? LiveNetworkModeSystemProvider.parseRouteGateway(route.standardOutput)
            : nil
        let defaultRoute = runner.run(executable: "/sbin/route", arguments: ["-n", "get", "default"])
        let physical = defaultRoute.succeeded
            ? LiveNetworkModeSystemProvider.parseRouteInterface(defaultRoute.standardOutput)
            : nil

        let directReady = carrier && ipv4 != nil && gateway != nil && directTargets.contains { target in
            httpProbe(target: target, arguments: ["--interface", interfaceName, "--noproxy", "*"])
        }
        let controllerReady = mihomo.isControllerAvailable()
        let clashReady = controllerReady && mihomo.probeHTTPS()
        let systemReady = directTargets.contains { httpProbe(target: $0, arguments: []) }

        return ConnectivityProbeResult(
            interfaceName: interfaceName,
            carrierActive: carrier,
            ipv4Address: ipv4,
            gateway: gateway,
            directHTTPSReachable: directReady,
            clashControllerReachable: controllerReady,
            clashHTTPSReachable: clashReady,
            systemHTTPSReachable: systemReady,
            physicalDefaultInterface: physical
        )
    }

    private func httpProbe(target: String, arguments: [String]) -> Bool {
        let result = runner.run(
            executable: "/usr/bin/curl",
            arguments: [
                "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                "--connect-timeout", "2", "--max-time", "4", "--max-redirs", "0"
            ] + arguments + [target]
        )
        guard result.succeeded,
              let status = Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        if target.contains("generate_204") { return status == 204 }
        return status == 200
    }
}

final class LiveWiFiCandidateController: NSObject, WiFiCandidateControlling, CWEventDelegate, CLLocationManagerDelegate {
    private let client = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private let runner: NetworkModeCommandRunning
    private var onChange: (() -> Void)?

    init(runner: NetworkModeCommandRunning = DefaultNetworkModeCommandRunner()) {
        self.runner = runner
        super.init()
        locationManager.delegate = self
    }

    func snapshot(pinnedSSIDs: [String]) -> WiFiCandidateSnapshot {
        #if APP_STORE
        return .init(candidates: [], currentSSID: nil, savedSSIDs: [], visibleSSIDs: [], locationAccess: .restricted)
        #else
        guard let interface = client.interface() else {
            return .init(candidates: [], currentSSID: nil, savedSSIDs: [], visibleSSIDs: [], locationAccess: locationAccess)
        }
        let profiles = interface.configuration()?.networkProfiles.array.compactMap { $0 as? CWNetworkProfile } ?? []
        let saved = Set(profiles.compactMap(\.ssid).filter { !$0.isEmpty })
        let current = interface.ssid() ?? currentSSIDFromIPConfig()
        var visibleSignals: [String: Int] = [:]
        var securedSSIDs = Set<String>()
        if locationAccess == .allowed,
           let networks = try? interface.scanForNetworks(withName: nil) {
            for network in networks {
                guard let ssid = network.ssid, saved.contains(ssid) else { continue }
                guard !network.supportsSecurity(.none) else { continue }
                visibleSignals[ssid] = max(visibleSignals[ssid] ?? Int.min, network.rssiValue)
                securedSSIDs.insert(ssid)
            }
        }
        if let current, saved.contains(current), visibleSignals[current] == nil {
            visibleSignals[current] = 0
            if interface.security() != .none { securedSSIDs.insert(current) }
        }
        let candidates = WiFiCandidateSelector.select(
            pinnedSSIDs: pinnedSSIDs,
            savedSSIDs: saved,
            visibleSignals: visibleSignals,
            securedSSIDs: securedSSIDs,
            currentSSID: current,
            locationAccess: locationAccess
        )
        return .init(
            candidates: candidates,
            currentSSID: current,
            savedSSIDs: saved,
            visibleSSIDs: Set(visibleSignals.keys),
            locationAccess: locationAccess
        )
        #endif
    }

    func associate(ssid: String) -> WiFiAssociationResult {
        #if APP_STORE
        return .unavailable
        #else
        guard !ssid.isEmpty else { return .unavailable }
        let result = runner.run(
            executable: "/usr/sbin/networksetup",
            arguments: Self.associationArguments(ssid: ssid)
        )
        guard result.succeeded else {
            let message = result.combinedMessage.lowercased()
            if message.contains("authorization") || message.contains("administrator") || message.contains("not authorized") {
                return .authorizationRequired
            }
            return .failed(result.combinedMessage.isEmpty ? "Wi-Fi 关联失败" : result.combinedMessage)
        }
        for _ in 0..<12 {
            if client.interface()?.ssid() == ssid || currentSSIDFromIPConfig() == ssid {
                return .connected
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return .failed("Wi-Fi 关联命令已执行，但未在 12 秒内完成连接")
        #endif
    }

    static func associationArguments(ssid: String) -> [String] {
        ["-setairportnetwork", "en0", ssid]
    }

    func requestLocationAccess() {
        #if !APP_STORE
        locationManager.requestWhenInUseAuthorization()
        #endif
    }

    func startMonitoring(onChange: @escaping () -> Void) {
        self.onChange = onChange
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        try? client.startMonitoringEvent(with: .powerDidChange)
    }

    func stopMonitoring() {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
        onChange = nil
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { onChange?() }

    private var locationAccess: WiFiLocationAccessState {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }

    private func currentSSIDFromIPConfig() -> String? {
        let result = runner.run(executable: "/usr/sbin/ipconfig", arguments: ["getsummary", "en0"])
        guard result.succeeded else { return nil }
        for line in result.standardOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SSID :") || trimmed.hasPrefix("SSID:") else { continue }
            let value = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty, value != "<redacted>" { return value }
        }
        return nil
    }
}

final class NetworkChangeObserver {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkChangeObserver>.fromOpaque(info).takeUnretainedValue().onChange?()
        }
        guard let store = SCDynamicStoreCreate(nil, "com.zjah.NetBar.network-change" as CFString, callback, &context) else { return }
        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Interface/en0/IPv4",
            "State:/Network/Interface/en0/Link",
            "State:/Network/Interface/bridge0/IPv4",
            "State:/Network/Interface/bridge0/Link"
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)
        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        self.store = store
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        store = nil
        onChange = nil
    }
}

protocol NetworkEventLogging {
    func record(event: String, detail: String, candidateSSID: String?)
}

final class NetworkEventLogger: NetworkEventLogging {
    static let shared = NetworkEventLogger()
    private let queue = DispatchQueue(label: "com.zjah.NetBar.network-event-log")
    private let fileURL: URL
    private let maxBytes: UInt64 = 2 * 1024 * 1024

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NetBar/network-events.jsonl")
    }

    func record(event: String, detail: String, candidateSSID: String? = nil) {
        queue.async { [fileURL, maxBytes] in
            let fm = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let candidateID = candidateSSID.map(WiFiCandidateSelector.candidateID(for:))
            let safeDetail = candidateSSID.map { detail.replacingOccurrences(of: $0, with: "<candidate>") } ?? detail
            let payload: [String: String] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "event": event,
                "detail": safeDetail,
                "candidate": candidateID ?? "-"
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else { return }
            line.append(0x0A)
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            var retained = existing.components(separatedBy: .newlines).compactMap { raw -> String? in
                guard !raw.isEmpty,
                      let rawData = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: rawData) as? [String: String],
                      let timestamp = object["timestamp"],
                      let date = ISO8601DateFormatter().date(from: timestamp),
                      date >= cutoff else { return nil }
                return raw
            }
            retained.append(String(decoding: line.dropLast(), as: UTF8.self))
            var output = Data((retained.joined(separator: "\n") + "\n").utf8)
            if UInt64(output.count) > maxBytes {
                let suffix = output.suffix(Int(maxBytes))
                if let newline = suffix.firstIndex(of: 0x0A) {
                    output = Data(suffix[suffix.index(after: newline)...])
                } else {
                    output = Data(suffix)
                }
            }
            try? output.write(to: fileURL, options: .atomic)
        }
    }
}
