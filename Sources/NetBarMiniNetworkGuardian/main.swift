import NetworkExecution
import Foundation
import NetBarMiniNetworkGuardianSupport
import os
import SystemConfiguration

private struct GuardianProfile: Decodable {
    let managementMiniAddress: String
    let managementSubnetMask: String
    let miniUpstreamDevice: String
    let miniUpstreamAddress: String
    let miniUpstreamSubnetMask: String
    let miniUpstreamRouter: String
    let probeTargets: [String]
    let httpsProbeTargets: [String]
}

/// Raw values are a wire contract with the MacBook's `MacMiniGatewayState`; never rename one.
/// `recoveryBackoff` no longer means a repair backoff (there are no repairs left) — it is kept as
/// the value for "the Guardian itself could not complete an observation", because every shipped
/// MacBook build already decodes it.
private enum GuardianState: String, Codable {
    case carrierDown
    case addressRecovering
    case sharingRecovering
    case readyStabilizing
    case ready
    case configurationDrift
    case recoveryBackoff
    case sharingManualPending
    case managementLinkRecovering
    case upstreamUnreachable
}

private struct GuardianStatus: Codable {
    var state: GuardianState
    var observedAt: String?
    var generation: UInt64
    var lastTransition: String?
    var lastCarrierChange: String? = nil
    var lastAction: String?
    var lastError: String?
    var carrierActive: Bool
    var addressReady: Bool
    var routeReady: Bool
    var sharingRunning: Bool
    var forwardingEnabled: Bool
    var sharingConfigured: Bool
    var upstreamReachable: Bool
    var managementAddressReady: Bool
    var bridgeUsesDHCP: Bool
    var sharingIntentEnabled: Bool
    var dhcpServerEnabled: Bool? = nil
    var hotspotAPConfigured: Bool
    var hotspotAPActive: Bool
    var hotspotClientObserved: Bool
    var guardianVersion: Int? = nil
}

private struct CommandResult {
    let status: Int32
    let output: String
    var succeeded: Bool { status == 0 }
}

private final class CommandRunner {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let result = BoundedCommand.run(executable, arguments, timeout: executable.hasSuffix("curl") ? 4 : 2)
        return CommandResult(status: result.exitCode, output: result.stdout + result.stderr)
    }
}

/// Observes Apple Internet Sharing on the Mac mini and keeps the Thunderbolt management alias alive.
///
/// The Guardian never touches the sharing daemon: the signal-and-relaunch path was removed after
/// two incidents in which it left sharing permanently stopped (Apple's graceful teardown
/// disables its DHCP server and a relaunched instance carries no "enable" intent — only System
/// Settings can restore it).  Its single write is `ifconfig bridge0 alias`, so SSH/VNC to the Mini
/// survive whatever sharing does.
private final class MiniNetworkGuardian {
    /// Bumped whenever the MacBook must insist on a reinstall (it shows the update button when
    /// the reported version is older than what it requires).  2 = observe-only Guardian.
    static let version = 2
    /// Telemetry (bound HTTPS via en0, `system_profiler`) is slow; sample it at most this often
    /// and always after the verdict has been written, so it can never stall a status refresh.
    private static let telemetryInterval: TimeInterval = 60

    private let profileURL = URL(fileURLWithPath: "/Library/Application Support/NetBar/MacMiniLinkProfile.plist")
    private let statusURL = URL(fileURLWithPath: "/Library/Application Support/NetBar/MiniGuardian/status.json")
    private let natProfileURL = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.nat.plist")
    private let bootpdProfileURL = URL(fileURLWithPath: "/etc/bootpd.plist")
    private let runner = CommandRunner()
    private let queue = DispatchQueue(label: "com.zjah.NetBarMiniNetworkGuardian")
    private let iso8601 = ISO8601DateFormatter()
    private let log = Logger(subsystem: "com.zjah.NetBarMiniNetworkGuardian", category: "network")
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var sharingWaitStarted: Date?
    private var healthySince: Date?
    private var telemetryProbedAt: Date?
    private var cachedUpstreamReachable = false
    private var previousCarrier: Bool?
    private var status: GuardianStatus
    private let profile: GuardianProfile

    private struct AliasMaintenance {
        let restorable: Bool
        let failure: String?
    }

    init?() {
        guard let data = try? Data(contentsOf: profileURL),
              let decoded = try? PropertyListDecoder().decode(GuardianProfile.self, from: data),
              decoded.miniUpstreamDevice == "en0" else {
            return nil
        }
        profile = decoded
        status = Self.loadStatus(from: statusURL) ?? GuardianStatus(
            state: .recoveryBackoff,
            observedAt: nil,
            generation: 0,
            lastTransition: nil,
            lastAction: nil,
            lastError: "guardian starting",
            carrierActive: false,
            addressReady: false,
            routeReady: false,
            sharingRunning: false,
            forwardingEnabled: false,
            sharingConfigured: false,
            upstreamReachable: false,
            managementAddressReady: false,
            bridgeUsesDHCP: false,
            sharingIntentEnabled: false,
            dhcpServerEnabled: nil,
            hotspotAPConfigured: false,
            hotspotAPActive: false,
            hotspotClientObserved: false
        )
        cachedUpstreamReachable = status.upstreamReachable
    }

    func run() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let guardian = Unmanaged<MiniNetworkGuardian>.fromOpaque(info).takeUnretainedValue()
            guardian.scheduleEvaluation(after: 0)
        }
        guard let store = SCDynamicStoreCreate(
            nil,
            "com.zjah.NetBarMiniNetworkGuardian" as CFString,
            callback,
            &context
        ) else {
            transition(to: .recoveryBackoff, error: "unable to create SCDynamicStore")
            return
        }
        self.store = store
        let keys = [
            "State:/Network/Interface/\(profile.miniUpstreamDevice)/Link",
            "State:/Network/Global/IPv4"
        ] as CFArray
        let patterns = [
            "State:/Network/Service/.*/IPv4",
            "Setup:/Network/Service/.*/IPv4"
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            transition(to: .recoveryBackoff, error: "unable to create SCDynamicStore run loop source")
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        scheduleEvaluation(after: 0)
        CFRunLoopRun()
    }

    private func scheduleEvaluation(after delay: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler { [weak self] in self?.evaluate() }
            self.timer = timer
            timer.resume()
        }
    }

    private func evaluate() {
        // Verdict first, on its own budget; telemetry afterwards on another.  A slow probe can
        // therefore delay the telemetry fields but never the state the MacBook acts on.
        let observed = ProbeContext.withValue(ProbeContext(timeout: 12)) { evaluateFacts() }
        guard observed else { return }
        ProbeContext.withValue(ProbeContext(timeout: 12)) { refreshTelemetry() }
    }

    /// Returns false when the observation ran out of budget and the previous facts were kept.
    private func evaluateFacts() -> Bool {
        let now = Date()
        status.generation &+= 1
        let alias = maintainManagementAliasFirst()
        let carrier = interfaceIsActive()
        let addressReady = interfaceHasExpectedAddress()
        let routeReady = scopedDefaultRouteIsExpected()
        let sharingConfigured = sharingConfigurationMatches()
        let sharingIntentEnabled = sharingIntentIsEnabled()
        let dhcpServerEnabled = bootpdDHCPIsEnabled()
        let managementAddressReady = managementAliasIsReady()
        let bridgeUsesDHCP = bridgeServiceUsesDHCP()
        let sharedAddressReady = sharedBridgeAddressIsReady()
        let hotspotAPConfigured = hotspotIsConfigured()
        let sharingRunning = internetSharingIsRunning()
        let forwardingEnabled = kernelForwardingIsEnabled()
        let preferencesMatch = carrier ? preferencesMatchExpectedConfiguration() : true

        guard ProbeContext.current?.isStopped != true else {
            // Facts are incomplete: keep the previous facts *and* the previous `observedAt`, so the
            // MacBook sees a stale Guardian rather than a freshly stamped guess.
            transition(to: .recoveryBackoff, error: "observation timed out; retaining previous facts")
            scheduleEvaluation(after: 5)
            return false
        }
        status.observedAt = iso8601.string(from: now)
        status.guardianVersion = Self.version
        status.carrierActive = carrier
        status.addressReady = addressReady
        status.routeReady = routeReady
        status.sharingConfigured = sharingConfigured
        status.sharingRunning = sharingRunning
        status.forwardingEnabled = forwardingEnabled
        status.managementAddressReady = managementAddressReady
        status.bridgeUsesDHCP = bridgeUsesDHCP
        status.sharingIntentEnabled = sharingIntentEnabled
        status.dhcpServerEnabled = dhcpServerEnabled
        status.hotspotAPConfigured = hotspotAPConfigured
        status.upstreamReachable = cachedUpstreamReachable

        if previousCarrier != carrier {
            previousCarrier = carrier
            status.lastCarrierChange = iso8601.string(from: now)
            sharingWaitStarted = nil
            healthySince = nil
            transition(to: carrier ? .addressRecovering : .carrierDown, action: "carrier \(carrier ? "active" : "inactive")")
        }

        let facts = MiniGuardianServingFacts(
            carrierActive: carrier,
            preferencesMatch: preferencesMatch,
            sharingConfigured: sharingConfigured,
            sharingIntentEnabled: sharingIntentEnabled,
            dhcpServerEnabled: dhcpServerEnabled,
            managementAddressReady: managementAddressReady,
            managementAliasRestorable: managementAddressReady || alias.restorable,
            bridgeUsesDHCP: bridgeUsesDHCP,
            sharedAddressReady: sharedAddressReady,
            addressReady: addressReady,
            routeReady: routeReady,
            sharingRunning: sharingRunning,
            forwardingEnabled: forwardingEnabled,
            upstreamReachable: cachedUpstreamReachable
        )
        // Shared with the planner so the two cannot drift: this drives `healthySince`, which is fed
        // back in as `healthyElapsed`, so a divergence here would silently change when the Mini is
        // considered stable.
        if MiniGuardianRecoveryPlanner.isFullyHealthy(facts) {
            if healthySince == nil { healthySince = now }
        } else {
            healthySince = nil
        }
        let decision = MiniGuardianRecoveryPlanner.decide(
            facts,
            sharingWaitElapsed: sharingWaitStarted.map { now.timeIntervalSince($0) },
            healthyElapsed: healthySince.map { now.timeIntervalSince($0) }
        )

        switch decision {
        case .carrierDown:
            transition(to: .carrierDown)
            scheduleEvaluation(after: 15)

        case .configurationDrift(let message):
            transition(to: .configurationDrift, error: message)
            scheduleEvaluation(after: 15)

        case .managementLinkRecovering:
            // The alias write already happened at the top of this round; surface its failure text
            // instead of pretending a silent retry is progress.
            transition(to: .managementLinkRecovering, error: alias.failure)
            scheduleEvaluation(after: 5)

        case .addressRecovering:
            transition(to: .addressRecovering)
            scheduleEvaluation(after: 15)

        case .sharingRecovering(let reason, let remaining):
            if sharingWaitStarted == nil { sharingWaitStarted = now }
            transition(to: .sharingRecovering, error: reason)
            // Never sleep past the MacBook's freshness window: it must keep seeing a live Guardian
            // while Apple rebuilds sharing.
            scheduleEvaluation(after: min(15, max(1, remaining)))

        case .sharingManualPending(let reason):
            transition(to: .sharingManualPending, error: reason)
            scheduleEvaluation(after: 15)

        case .upstreamUnreachable:
            transition(to: .upstreamUnreachable, error: "bound HTTPS probe via \(profile.miniUpstreamDevice) failed")
            scheduleEvaluation(after: 15)

        case .readyStabilizing(let delay):
            transition(to: .readyStabilizing)
            scheduleEvaluation(after: min(15, max(1, delay)))

        case .ready:
            transition(to: .ready, action: status.lastAction)
            scheduleEvaluation(after: 15)
        }

        // The "not serving" window survives only the two states it explains.  Manual pending with
        // sharing switched off is the user's intent, not a stuck rebuild, so it does not keep it.
        switch decision {
        case .sharingRecovering:
            break
        case .sharingManualPending where sharingIntentEnabled:
            break
        default:
            sharingWaitStarted = nil
        }
        return true
    }

    /// Slow, informational facts.  They are written after the verdict and never change `state`;
    /// a flipped upstream sample only schedules the next verdict early.
    private func refreshTelemetry() {
        let now = Date()
        if let telemetryProbedAt, now.timeIntervalSince(telemetryProbedAt) < Self.telemetryInterval {
            return
        }
        telemetryProbedAt = now
        let upstream = boundUpstreamIsReachable()
        let upstreamChanged = upstream != cachedUpstreamReachable
        cachedUpstreamReachable = upstream
        status.upstreamReachable = upstream
        status.hotspotAPActive = hotspotAPIsActive()
        status.hotspotClientObserved = hotspotClientIsObserved()
        writeStatus()
        if upstreamChanged { scheduleEvaluation(after: 0) }
    }

    private func transition(to state: GuardianState, action: String? = nil, error: String? = nil) {
        let previousState = status.state
        let previousAction = status.lastAction
        let previousError = status.lastError
        if status.state != state {
            status.state = state
            status.lastTransition = iso8601.string(from: Date())
        }
        if let action { status.lastAction = action }
        status.lastError = error
        writeStatus()
        if previousState != status.state || previousAction != status.lastAction || previousError != status.lastError {
            self.log.notice("state=\(self.status.state.rawValue, privacy: .public) carrier=\(self.status.carrierActive) address=\(self.status.addressReady) route=\(self.status.routeReady) sharing=\(self.status.sharingRunning) forwarding=\(self.status.forwardingEnabled) dhcp=\(self.status.dhcpServerEnabled ?? false) egress=\(self.status.upstreamReachable) action=\(self.status.lastAction ?? "-", privacy: .public) error=\(self.status.lastError ?? "-", privacy: .public)")
        }
    }

    private func writeStatus() {
        do {
            let directory = statusURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(status)
            try data.write(to: statusURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path)
        } catch {
            fputs("NetBarMiniNetworkGuardian: \(error)\n", stderr)
        }
    }

    private static func loadStatus(from url: URL) -> GuardianStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GuardianStatus.self, from: data)
    }

    private func interfaceIsActive() -> Bool {
        runner.run("/sbin/ifconfig", [profile.miniUpstreamDevice]).output.contains("status: active")
    }

    private func interfaceHasExpectedAddress() -> Bool {
        runner.run("/sbin/ifconfig", [profile.miniUpstreamDevice]).output
            .contains("inet \(profile.miniUpstreamAddress) ")
    }

    private func scopedDefaultRouteIsExpected() -> Bool {
        let output = runner.run("/sbin/route", [
            "-n", "get", "-ifscope", profile.miniUpstreamDevice, "default"
        ]).output
        return output.contains("gateway: \(profile.miniUpstreamRouter)") &&
            output.contains("interface: \(profile.miniUpstreamDevice)")
    }

    private func internetSharingIsRunning() -> Bool {
        let output = runner.run("/bin/launchctl", ["print", "system/com.apple.NetworkSharing"]).output
        return output.contains("state = running") && output.contains("/usr/libexec/InternetSharing")
    }

    private func kernelForwardingIsEnabled() -> Bool {
        let result = runner.run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"])
        return result.succeeded && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func boundUpstreamIsReachable() -> Bool {
        profile.httpsProbeTargets.contains { target in
            let result = runner.run("/usr/bin/curl", [
                "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                "--connect-timeout", "2", "--max-time", "4", "--max-redirs", "0",
                "--interface", profile.miniUpstreamDevice,
                "--noproxy", "*", target
            ])
            guard result.succeeded,
                  let status = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return false
            }
            return target.contains("generate_204") ? status == 204 : status == 200
        }
    }

    private func preferencesMatchExpectedConfiguration() -> Bool {
        guard let service = findService(device: profile.miniUpstreamDevice) else { return false }
        let output = runner.run("/usr/sbin/networksetup", ["-getinfo", service]).output
        return output.contains("Manual Configuration") &&
            output.contains("IP address: \(profile.miniUpstreamAddress)") &&
            output.contains("Subnet mask: \(profile.miniUpstreamSubnetMask)") &&
            output.contains("Router: \(profile.miniUpstreamRouter)")
    }

    private func sharingConfigurationMatches() -> Bool {
        guard let data = try? Data(contentsOf: natProfileURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let nat = object["NAT"] as? [String: Any],
              let primary = nat["PrimaryInterface"] as? [String: Any],
              primary["Device"] as? String == profile.miniUpstreamDevice,
              let devices = nat["SharingDevices"] as? [String] else {
            return false
        }
        return devices.contains("bridge0") && devices.contains("en1")
    }

    private func sharingIntentIsEnabled() -> Bool {
        let object = (try? Data(contentsOf: natProfileURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            as? [String: Any]
        return GuardianInterfaceFacts.sharingIntentIsEnabled(natPlist: object)
    }

    private func bootpdDHCPIsEnabled() -> Bool {
        guard let data = try? Data(contentsOf: bootpdProfileURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return MiniGuardianRecoveryPlanner.appleDHCPEnabled(from: object["dhcp_enabled"])
    }

    /// The alias is written before anything else is observed, so a slow probe can never time the
    /// round out before the one write that keeps the Mini manageable.  Same identity, DHCP and
    /// address-conflict protection as before; the result is surfaced through the planner's
    /// `managementLinkRecovering` verdict instead of being logged and forgotten.
    private func maintainManagementAliasFirst() -> AliasMaintenance {
        guard !managementAliasIsReady() else { return AliasMaintenance(restorable: true, failure: nil) }
        guard bridgeServiceUsesDHCP(), managementAliasCanBeRestored() else {
            return AliasMaintenance(restorable: false, failure: nil)
        }
        let result = runner.run("/sbin/ifconfig", [
            "bridge0", "alias", profile.managementMiniAddress,
            "netmask", profile.managementSubnetMask
        ])
        log.info("管理别名先行维护 succeeded=\(result.succeeded, privacy: .public)")
        if result.succeeded { status.lastAction = "restored Thunderbolt management alias" }
        return AliasMaintenance(restorable: true, failure: result.succeeded ? nil : result.output)
    }

    private func managementAliasCanBeRestored() -> Bool {
        let result = runner.run("/sbin/ifconfig", ["-a"])
        guard result.succeeded else { return false }
        return GuardianInterfaceFacts.managementAliasCanBeRestored(
            ifconfigOutput: result.output,
            managementSubnetPrefix: GuardianInterfaceFacts.managementSubnetPrefix(
                forAddress: profile.managementMiniAddress
            )
        )
    }

    private func managementAliasIsReady() -> Bool {
        runner.run("/sbin/ifconfig", ["bridge0"]).output
            .contains("inet \(profile.managementMiniAddress) ")
    }

    private func bridgeServiceUsesDHCP() -> Bool {
        guard let service = findService(device: "bridge0") else { return false }
        return runner.run("/usr/sbin/networksetup", ["-getinfo", service]).output
            .contains("DHCP Configuration")
    }

    private func sharedBridgeAddressIsReady() -> Bool {
        runner.run("/sbin/ifconfig", ["bridge0"]).output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("inet ") }
            .compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
            .contains { $0 != profile.managementMiniAddress && !$0.hasPrefix("169.254.") }
    }

    private func hotspotIsConfigured() -> Bool {
        guard let data = try? Data(contentsOf: natProfileURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let nat = object["NAT"] as? [String: Any],
              let devices = nat["SharingDevices"] as? [String] else {
            return false
        }
        return devices.contains("en1")
    }

    private func hotspotAPIsActive() -> Bool {
        let output = runner.run("/usr/sbin/system_profiler", ["SPAirPortDataType"]).output
        return output.contains("Network Type: Wi-Fi Internet Sharing")
    }

    private func hotspotClientIsObserved() -> Bool {
        let result = runner.run("/usr/sbin/arp", ["-an", "-i", "ap1"])
        return result.succeeded && result.output.contains(" at ")
    }

    private func findService(device: String) -> String? {
        NetworkServiceOrderParser.serviceName(
            forDevice: device,
            in: runner.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).output
        )
    }
}

guard let guardian = MiniNetworkGuardian() else {
    fputs("NetBarMiniNetworkGuardian: invalid or missing profile\n", stderr)
    exit(78)
}
guardian.run()
