import CoreLocation
import CoreWLAN
import CryptoKit
import Foundation
import SystemConfiguration

enum DNSConfigurationSource: String, Codable, Equatable {
    case automatic
    case manual
    case loopback
    case unknown
}

enum DNSResolverDependency: String, Codable, Equatable {
    case independent
    case miniDependent
    case unreachable
    case overlayOnly
    case unknown

    var displayName: String {
        switch self {
        case .independent: return "DNS 独立可用"
        case .miniDependent: return "DNS 仍依赖 Mac mini"
        case .unreachable: return "DNS 不可用"
        case .overlayOnly: return "DNS 由 TUN/本机代理接管"
        case .unknown: return "DNS 待检测"
        }
    }
}

struct DNSPathFacts: Equatable {
    let serviceName: String?
    let interfaceName: String
    let configurationSource: DNSConfigurationSource
    let dependency: DNSResolverDependency
    let resolverCount: Int
    let systemResolutionReady: Bool
    let generation: UInt64
    let observedAt: Date

    static func unknown(interfaceName: String) -> DNSPathFacts {
        .init(
            serviceName: nil,
            interfaceName: interfaceName,
            configurationSource: .unknown,
            dependency: .unknown,
            resolverCount: 0,
            systemResolutionReady: false,
            generation: 0,
            observedAt: .distantPast
        )
    }
}

struct ApplicationPathFacts: Equatable {
    let systemProxyAwareHTTPSReady: Bool
    let explicitClashHTTPSReady: Bool
    let proxyUnawareHTTPSReady: Bool
    let zcodeDiagnosticReady: Bool
    let zcodeHTTPStatus: Int?
    let generation: UInt64
    let observedAt: Date

    init(
        systemProxyAwareHTTPSReady: Bool,
        explicitClashHTTPSReady: Bool,
        proxyUnawareHTTPSReady: Bool,
        zcodeDiagnosticReady: Bool,
        zcodeHTTPStatus: Int?,
        generation: UInt64 = 0,
        observedAt: Date = Date()
    ) {
        self.systemProxyAwareHTTPSReady = systemProxyAwareHTTPSReady
        self.explicitClashHTTPSReady = explicitClashHTTPSReady
        self.proxyUnawareHTTPSReady = proxyUnawareHTTPSReady
        self.zcodeDiagnosticReady = zcodeDiagnosticReady
        self.zcodeHTTPStatus = zcodeHTTPStatus
        self.generation = generation
        self.observedAt = observedAt
    }

    static let unknown = ApplicationPathFacts(
        systemProxyAwareHTTPSReady: false,
        explicitClashHTTPSReady: false,
        proxyUnawareHTTPSReady: false,
        zcodeDiagnosticReady: false,
        zcodeHTTPStatus: nil,
        generation: 0,
        observedAt: .distantPast
    )
}

enum ConnectivityProofLevel: String, Codable, Equatable {
    case unavailable
    case routeEligible
    case preflightEligible
    case activeVerified
    case degradedActive
}

enum NetworkConnectivityReasonCode: String, Codable, Equatable {
    case wifiDNSDependsOnMini
    case dnsResolverUnavailable
    case proxyUnawarePathUnavailable
    case tunDataPlaneUnavailable
    case zcodeEndpointUnavailable
    case miniDownstreamUnavailable
    case routeActiveDataPlaneDegraded
}

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
    let dnsPath: DNSPathFacts
    let applicationPath: ApplicationPathFacts

    init(
        interfaceName: String,
        carrierActive: Bool,
        ipv4Address: String?,
        gateway: String?,
        directHTTPSReachable: Bool,
        clashControllerReachable: Bool,
        clashHTTPSReachable: Bool,
        systemHTTPSReachable: Bool,
        physicalDefaultInterface: String?,
        dnsPath: DNSPathFacts? = nil,
        applicationPath: ApplicationPathFacts? = nil
    ) {
        self.interfaceName = interfaceName
        self.carrierActive = carrierActive
        self.ipv4Address = ipv4Address
        self.gateway = gateway
        self.directHTTPSReachable = directHTTPSReachable
        self.clashControllerReachable = clashControllerReachable
        self.clashHTTPSReachable = clashHTTPSReachable
        self.systemHTTPSReachable = systemHTTPSReachable
        self.physicalDefaultInterface = physicalDefaultInterface
        self.dnsPath = dnsPath ?? .unknown(interfaceName: interfaceName)
        self.applicationPath = applicationPath ?? .unknown
    }

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

    var proofLevel: ConnectivityProofLevel {
        guard hasLocalNetwork else { return .unavailable }
        let physicalMatches = physicalDefaultInterface == interfaceName
        let resolverReady = dnsPath.systemResolutionReady &&
            dnsPath.dependency != .miniDependent &&
            dnsPath.dependency != .unreachable &&
            dnsPath.dependency != .unknown
        let applicationReady = applicationPath.systemProxyAwareHTTPSReady &&
            (!clashControllerReachable || applicationPath.explicitClashHTTPSReady)
        guard resolverReady, applicationReady else {
            return physicalMatches ? .degradedActive : .routeEligible
        }
        guard applicationPath.proxyUnawareHTTPSReady else {
            return physicalMatches ? .degradedActive : .preflightEligible
        }
        return physicalMatches ? .activeVerified : .preflightEligible
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
        case .manualWiFi: return "Wi-Fi 优先"
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
    let interfaceName: String

    init(
        candidates: [NetworkAccessCandidate],
        currentSSID: String?,
        savedSSIDs: Set<String>,
        visibleSSIDs: Set<String>,
        locationAccess: WiFiLocationAccessState,
        interfaceName: String = "en0"
    ) {
        self.candidates = candidates
        self.currentSSID = currentSSID
        self.savedSSIDs = savedSSIDs
        self.visibleSSIDs = visibleSSIDs
        self.locationAccess = locationAccess
        self.interfaceName = interfaceName
    }
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
        locationAccess: WiFiLocationAccessState,
        anonymousCurrentAssociated: Bool = false,
        interfaceName: String = "en0"
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

        var candidates = displayOrder.map { ssid in
            NetworkAccessCandidate(
                id: candidateID(for: ssid),
                kind: .wifi,
                displayName: ssid,
                interfaceName: interfaceName,
                state: allowedVisible.contains(ssid) ? .localOnly : .unavailable,
                signalStrength: visibleSignals[ssid],
                isPinned: orderedPinned.contains(ssid),
                isCurrent: ssid == currentSSID
            )
        }
        if currentSSID == nil, anonymousCurrentAssociated {
            candidates.insert(anonymousCurrentCandidate(interfaceName: interfaceName), at: 0)
        }
        return candidates
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

    static func anonymousCurrentCandidate(interfaceName: String = "en0") -> NetworkAccessCandidate {
        NetworkAccessCandidate(
            id: anonymousCurrentID,
            kind: .wifi,
            displayName: "当前已连接 Wi-Fi",
            interfaceName: interfaceName,
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
    private let legacyMiniDNSAddress = "192.168.2.1"

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
        var physical = defaultRoute.succeeded
            ? LiveNetworkModeSystemProvider.parseRouteInterface(defaultRoute.standardOutput)
            : nil
        if physical?.hasPrefix("utun") == true || physical == nil {
            let nwi = runner.run(executable: "/usr/sbin/scutil", arguments: ["--nwi"])
            if nwi.succeeded {
                physical = LiveNetworkModeSystemProvider.parseNWIPrimaryPhysicalInterface(
                    nwi.standardOutput,
                    candidates: [interfaceName]
                )
            }
        }

        let directReady = carrier && ipv4 != nil && gateway != nil && directTargets.contains { target in
            httpProbe(target: target, arguments: ["--interface", interfaceName, "--noproxy", "*"])
        }
        let controllerReady = mihomo.isControllerAvailable()
        let clashReady = controllerReady && mihomo.probeHTTPS()
        let systemReady = directTargets.contains { httpProbe(target: $0, arguments: []) }
        let proxyUnawareReady = directTargets.contains {
            httpProbe(target: $0, arguments: ["--noproxy", "*"])
        }
        let dnsPath = inspectDNS(interfaceName: interfaceName)
        let zcode = httpStatus(
            target: "https://zcode.z.ai/api/v1/oauth/token",
            arguments: ["--noproxy", "*"]
        )
        let zcodeReady = zcode.map(Self.isAcceptableAnonymousApplicationStatus) ?? false
        let applicationPath = ApplicationPathFacts(
            systemProxyAwareHTTPSReady: systemReady,
            explicitClashHTTPSReady: clashReady,
            proxyUnawareHTTPSReady: proxyUnawareReady,
            zcodeDiagnosticReady: zcodeReady,
            zcodeHTTPStatus: zcode
        )

        return ConnectivityProbeResult(
            interfaceName: interfaceName,
            carrierActive: carrier,
            ipv4Address: ipv4,
            gateway: gateway,
            directHTTPSReachable: directReady,
            clashControllerReachable: controllerReady,
            clashHTTPSReachable: clashReady,
            systemHTTPSReachable: systemReady,
            physicalDefaultInterface: physical,
            dnsPath: dnsPath,
            applicationPath: applicationPath
        )
    }

    private func inspectDNS(interfaceName: String) -> DNSPathFacts {
        let order = runner.run(executable: "/usr/sbin/networksetup", arguments: ["-listnetworkserviceorder"])
        let service = order.succeeded
            ? LiveNetworkModeSystemProvider.parseServiceOrder(order.standardOutput).first(where: { $0.device == interfaceName })
            : nil
        let configured = service.map {
            runner.run(executable: "/usr/sbin/networksetup", arguments: ["-getdnsservers", $0.name])
        }
        let configuredServers = configured.flatMap { result -> [String]? in
            guard result.succeeded else { return nil }
            if result.standardOutput.contains("There aren't any DNS Servers") { return [] }
            return Self.parseDNSServers(result.standardOutput)
        }
        let scoped = runner.run(executable: "/usr/sbin/scutil", arguments: ["--dns"])
        let scopedServers = scoped.succeeded
            ? Self.parseScopedDNSServers(scoped.standardOutput, interfaceName: interfaceName)
            : []
        let resolvers = (configuredServers?.isEmpty == false ? configuredServers! : scopedServers)
        let resolution = runner.run(
            executable: "/usr/bin/dscacheutil",
            arguments: ["-q", "host", "-a", "name", "www.apple.com"]
        )
        let resolutionReady = resolution.succeeded && resolution.standardOutput.contains("ip_address:")
        let source: DNSConfigurationSource
        if resolvers.allSatisfy({ $0 == "127.0.0.1" || $0 == "::1" }), !resolvers.isEmpty {
            source = .loopback
        } else if let configuredServers {
            source = configuredServers.isEmpty ? .automatic : .manual
        } else {
            source = .unknown
        }
        let dependency: DNSResolverDependency
        if interfaceName != "bridge0", resolvers.contains(legacyMiniDNSAddress) {
            dependency = .miniDependent
        } else if source == .loopback {
            dependency = resolutionReady ? .overlayOnly : .unreachable
        } else if !resolutionReady {
            dependency = .unreachable
        } else if resolvers.isEmpty {
            dependency = .unknown
        } else {
            let routeInterfaces = resolvers.compactMap { resolver -> String? in
                let route = runner.run(executable: "/sbin/route", arguments: ["-n", "get", resolver])
                return route.succeeded
                    ? LiveNetworkModeSystemProvider.parseRouteInterface(route.standardOutput)
                    : nil
            }
            if routeInterfaces.contains(where: { $0.hasPrefix("utun") }) {
                dependency = .overlayOnly
            } else if interfaceName != "bridge0", routeInterfaces.contains("bridge0") {
                dependency = .miniDependent
            } else {
                dependency = .independent
            }
        }
        return DNSPathFacts(
            serviceName: service?.name,
            interfaceName: interfaceName,
            configurationSource: source,
            dependency: dependency,
            resolverCount: resolvers.count,
            systemResolutionReady: resolutionReady,
            generation: 0,
            observedAt: Date()
        )
    }

    static func parseDNSServers(_ output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("There aren't any DNS Servers") }
    }

    static func isAcceptableAnonymousApplicationStatus(_ status: Int) -> Bool {
        (200..<500).contains(status)
    }

    static func parseScopedDNSServers(_ output: String, interfaceName: String) -> [String] {
        var currentServers: [String] = []
        var currentInterface: String?
        var result: [String] = []
        func flush() {
            if currentInterface == interfaceName { result.append(contentsOf: currentServers) }
            currentServers = []
            currentInterface = nil
        }
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("resolver #") { flush() }
            if trimmed.hasPrefix("nameserver[") {
                if let value = trimmed.split(separator: ":", maxSplits: 1).last {
                    currentServers.append(value.trimmingCharacters(in: .whitespaces))
                }
            }
            if trimmed.hasPrefix("if_index"), let open = trimmed.lastIndex(of: "(") {
                let suffix = trimmed[trimmed.index(after: open)...]
                currentInterface = suffix.split(separator: ")").first.map(String.init)
            }
        }
        flush()
        return Array(Set(result)).sorted()
    }

    private func httpProbe(target: String, arguments: [String]) -> Bool {
        guard let status = httpStatus(target: target, arguments: arguments) else { return false }
        if target.contains("generate_204") { return status == 204 }
        return status == 200
    }

    private func httpStatus(target: String, arguments: [String]) -> Int? {
        let result = runner.run(
            executable: "/usr/bin/curl",
            arguments: [
                "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                "--connect-timeout", "2", "--max-time", "4", "--max-redirs", "0"
            ] + arguments + [target]
        )
        guard result.succeeded else { return nil }
        return Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
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
        let interfaceName = interface.interfaceName ?? "en0"
        let profiles = interface.configuration()?.networkProfiles.array.compactMap { $0 as? CWNetworkProfile } ?? []
        let saved = Set(profiles.compactMap(\.ssid).filter { !$0.isEmpty })
        let current = interface.ssid() ?? currentSSIDFromIPConfig(interfaceName: interfaceName)
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
            locationAccess: locationAccess,
            anonymousCurrentAssociated: current == nil && hasActiveWiFiAddress(interfaceName: interfaceName),
            interfaceName: interfaceName
        )
        return .init(
            candidates: candidates,
            currentSSID: current,
            savedSSIDs: saved,
            visibleSSIDs: Set(visibleSignals.keys),
            locationAccess: locationAccess,
            interfaceName: interfaceName
        )
        #endif
    }

    func associate(ssid: String) -> WiFiAssociationResult {
        #if APP_STORE
        return .unavailable
        #else
        guard !ssid.isEmpty else { return .unavailable }
        let interfaceName = client.interface()?.interfaceName ?? "en0"
        let result = runner.run(
            executable: "/usr/sbin/networksetup",
            arguments: Self.associationArguments(ssid: ssid, interfaceName: interfaceName)
        )
        guard result.succeeded else {
            let message = result.combinedMessage.lowercased()
            if message.contains("authorization") || message.contains("administrator") || message.contains("not authorized") {
                return .authorizationRequired
            }
            return .failed(result.combinedMessage.isEmpty ? "Wi-Fi 关联失败" : result.combinedMessage)
        }
        for _ in 0..<12 {
            if client.interface()?.ssid() == ssid || currentSSIDFromIPConfig(interfaceName: interfaceName) == ssid {
                return .connected
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return .failed("Wi-Fi 关联命令已执行，但未在 12 秒内完成连接")
        #endif
    }

    static func associationArguments(ssid: String, interfaceName: String = "en0") -> [String] {
        ["-setairportnetwork", interfaceName, ssid]
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

    private func currentSSIDFromIPConfig(interfaceName: String) -> String? {
        let result = runner.run(executable: "/usr/sbin/ipconfig", arguments: ["getsummary", interfaceName])
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

    private func hasActiveWiFiAddress(interfaceName: String) -> Bool {
        let address = runner.run(executable: "/usr/sbin/ipconfig", arguments: ["getifaddr", interfaceName])
        guard address.succeeded,
              !address.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let interface = runner.run(executable: "/sbin/ifconfig", arguments: [interfaceName])
        return interface.succeeded && interface.standardOutput.contains("status: active")
    }
}

enum NetworkChangeEvent: Equatable {
    case physicalLink
    case addressing
    case routing
    case dns
    case other

    static func classify(changedKeys: [String]) -> NetworkChangeEvent {
        if changedKeys.contains(where: { $0.hasSuffix("/Link") }) {
            return .physicalLink
        }
        if changedKeys.contains(where: { $0.hasSuffix("/IPv4") && $0.contains("/Interface/") }) {
            return .addressing
        }
        if changedKeys.contains("State:/Network/Global/IPv4") {
            return .routing
        }
        if changedKeys.contains(where: { $0.hasSuffix("/DNS") }) {
            return .dns
        }
        return .other
    }

    func reaction(
        preference: NetworkRoutePreference,
        activeMode: NetworkRouteMode?
    ) -> NetworkChangeReaction {
        switch self {
        case .physicalLink:
            return NetworkChangeReaction(
                delay: 0.1,
                message: preference == .miniPreferred && activeMode == .macMiniGateway
                    ? "检测到雷雳链路变化，正在确认并回退 Wi-Fi…"
                    : nil
            )
        case .addressing, .routing, .dns:
            return NetworkChangeReaction(delay: 0.2, message: nil)
        case .other:
            return NetworkChangeReaction(delay: 0.5, message: nil)
        }
    }
}

struct NetworkChangeReaction: Equatable {
    let delay: TimeInterval
    let message: String?
}

final class NetworkChangeObserver {
    static let notificationKeys = [
        "State:/Network/Global/IPv4",
        "State:/Network/Global/DNS",
        "State:/Network/Interface/en0/IPv4",
        "State:/Network/Interface/en0/Link",
        "State:/Network/Interface/bridge0/IPv4",
        "State:/Network/Interface/bridge0/Link"
    ]
    static let notificationPatterns = [
        #"State:/Network/Interface/.*/Link"#,
        #"State:/Network/Interface/.*/IPv4"#,
        #"State:/Network/Service/.*/DNS"#,
        #"Setup:/Network/Service/.*/DNS"#
    ]

    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var onChange: ((NetworkChangeEvent) -> Void)?

    func start(onChange: @escaping (NetworkChangeEvent) -> Void) {
        stop()
        self.onChange = onChange
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, changedKeys, info in
            guard let info else { return }
            let keys = changedKeys as? [String] ?? []
            let observer = Unmanaged<NetworkChangeObserver>.fromOpaque(info).takeUnretainedValue()
            observer.onChange?(NetworkChangeEvent.classify(changedKeys: keys))
        }
        guard let store = SCDynamicStoreCreate(nil, "com.zjah.NetBar.network-change" as CFString, callback, &context) else { return }
        SCDynamicStoreSetNotificationKeys(
            store,
            Self.notificationKeys as CFArray,
            Self.notificationPatterns as CFArray
        )
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
    private let duplicateSuppressionWindow: TimeInterval = 300
    private var lastRecordedByFingerprint: [String: Date] = [:]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NetBar/network-events.jsonl")
    }

    func record(event: String, detail: String, candidateSSID: String? = nil) {
        queue.async { [weak self, fileURL, maxBytes] in
            guard let self else { return }
            let fm = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let candidateID = candidateSSID.map(WiFiCandidateSelector.candidateID(for:))
            let safeDetail = candidateSSID.map { detail.replacingOccurrences(of: $0, with: "<candidate>") } ?? detail
            let now = Date()
            let fingerprint = [event, safeDetail, candidateID ?? "-"].joined(separator: "\u{1f}")
            if let last = self.lastRecordedByFingerprint[fingerprint],
               now.timeIntervalSince(last) < self.duplicateSuppressionWindow {
                return
            }
            self.lastRecordedByFingerprint[fingerprint] = now
            self.lastRecordedByFingerprint = self.lastRecordedByFingerprint.filter {
                now.timeIntervalSince($0.value) < self.duplicateSuppressionWindow
            }
            let payload: [String: String] = [
                "timestamp": ISO8601DateFormatter().string(from: now),
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
