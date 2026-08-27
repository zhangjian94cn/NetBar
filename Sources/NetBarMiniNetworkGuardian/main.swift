import Foundation
import NetBarMiniNetworkGuardianSupport
import os
import SystemConfiguration

private struct GuardianProfile: Decodable {
    let miniUpstreamDevice: String
    let miniUpstreamAddress: String
    let miniUpstreamSubnetMask: String
    let miniUpstreamRouter: String
    let probeTargets: [String]
}

private enum GuardianState: String, Codable {
    case carrierDown
    case addressRecovering
    case sharingRecovering
    case readyStabilizing
    case ready
    case configurationDrift
    case recoveryBackoff
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
    var nextRetryAt: String?
    var failureCount: Int
}

private struct CommandResult {
    let status: Int32
    let output: String
    var succeeded: Bool { status == 0 }
}

private final class CommandRunner {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

private final class MiniNetworkGuardian {
    private let profileURL = URL(fileURLWithPath: "/Library/Application Support/NetBar/MacMiniLinkProfile.plist")
    private let statusURL = URL(fileURLWithPath: "/Library/Application Support/NetBar/MiniGuardian/status.json")
    private let downstreamEgressFailureURL = URL(fileURLWithPath: "/Library/Application Support/NetBar/MiniGuardian/downstream-egress-failure.txt")
    private let natProfileURL = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.nat.plist")
    private let runner = CommandRunner()
    private let queue = DispatchQueue(label: "com.zjah.NetBarMiniNetworkGuardian")
    private let iso8601 = ISO8601DateFormatter()
    private let log = Logger(subsystem: "com.zjah.NetBarMiniNetworkGuardian", category: "network")
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var addressWaitStarted: Date?
    private var sharingWaitStarted: Date?
    private var pendingRepairVerification = false
    private var healthySince: Date?
    private var lastUpstreamProbeAt: Date?
    private var cachedUpstreamReachable = false
    private var previousCarrier: Bool?
    private var status: GuardianStatus
    private let profile: GuardianProfile

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
            nextRetryAt: nil,
            failureCount: 0
        )
        if GuardianPersistedRecoveryMigration.shouldResetBackoff(lastError: status.lastError) {
            status.failureCount = 0
            status.nextRetryAt = nil
            status.lastError = "retrying with SIP-safe native sharing restart"
        }
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
        let now = Date()
        status.observedAt = iso8601.string(from: now)
        status.generation &+= 1
        let carrier = interfaceIsActive()
        let addressReady = interfaceHasExpectedAddress()
        let routeReady = scopedDefaultRouteIsExpected()
        let sharingConfigured = sharingConfigurationMatches()
        let sharingRunning = internetSharingIsRunning()
        let forwardingEnabled = kernelForwardingIsEnabled()
        let reachable = addressReady && routeReady && upstreamReachability(at: now)
        let freshDownstreamFailure = consumeFreshDownstreamEgressFailure(at: now)
        let downstreamRecoveryRequested = freshDownstreamFailure && carrier && addressReady && routeReady &&
            sharingConfigured && sharingRunning && forwardingEnabled && reachable

        status.carrierActive = carrier
        status.addressReady = addressReady
        status.routeReady = routeReady
        status.sharingConfigured = sharingConfigured
        status.sharingRunning = sharingRunning
        status.forwardingEnabled = forwardingEnabled
        status.upstreamReachable = reachable

        if previousCarrier != carrier {
            previousCarrier = carrier
            status.lastCarrierChange = iso8601.string(from: now)
            addressWaitStarted = nil
            sharingWaitStarted = nil
            pendingRepairVerification = false
            lastUpstreamProbeAt = nil
            cachedUpstreamReachable = false
            status.failureCount = 0
            status.nextRetryAt = nil
            transition(to: carrier ? .addressRecovering : .carrierDown, action: "carrier \(carrier ? "active" : "inactive")")
        }

        let fullyHealthy = carrier && addressReady && routeReady && sharingRunning && forwardingEnabled && reachable
        if fullyHealthy {
            if healthySince == nil { healthySince = now }
        } else {
            healthySince = nil
        }
        let retryRemaining = parseDate(status.nextRetryAt).map { $0.timeIntervalSince(now) }
        let decision = MiniGuardianRecoveryPlanner.decide(
            MiniGuardianRecoveryInput(
                carrierActive: carrier,
                preferencesMatch: carrier ? preferencesMatchExpectedConfiguration() : true,
                sharingConfigured: sharingConfigured,
                addressReady: addressReady,
                routeReady: routeReady,
                sharingRunning: sharingRunning,
                forwardingEnabled: forwardingEnabled,
                downstreamEgressFailureReported: downstreamRecoveryRequested,
                upstreamReachable: reachable,
                pendingRepairVerification: pendingRepairVerification,
                retryRemaining: retryRemaining,
                addressWaitElapsed: addressWaitStarted.map { now.timeIntervalSince($0) },
                sharingWaitElapsed: sharingWaitStarted.map { now.timeIntervalSince($0) },
                healthyElapsed: healthySince.map { now.timeIntervalSince($0) }
            )
        )

        switch decision {
        case .carrierDown:
            transition(to: .carrierDown)
            scheduleEvaluation(after: 15)

        case .configurationDrift(let message):
            transition(to: .configurationDrift, error: message)
            scheduleEvaluation(after: 15)

        case .readyStabilizing(let delay):
            addressWaitStarted = nil
            sharingWaitStarted = nil
            pendingRepairVerification = false
            transition(to: .readyStabilizing)
            scheduleEvaluation(after: min(15, delay))

        case .ready(let resetBackoff):
            addressWaitStarted = nil
            sharingWaitStarted = nil
            pendingRepairVerification = false
            if resetBackoff {
                status.failureCount = 0
                status.nextRetryAt = nil
            }
            transition(to: .ready, action: status.lastAction)
            scheduleEvaluation(after: 15)

        case .repairFailed:
            pendingRepairVerification = false
            registerFailure(now: now, message: "repair did not reach a healthy state")

        case .recoveryBackoff(let delay):
            transition(to: .recoveryBackoff, error: status.lastError)
            scheduleEvaluation(after: GuardianEvaluationCadence.duringRecoveryBackoff(remaining: delay))

        case .addressRecovering(let delay):
            if addressWaitStarted == nil { addressWaitStarted = now }
            transition(to: .addressRecovering)
            scheduleEvaluation(after: delay)

        case .reapplyAddress:
            let service = findService(device: profile.miniUpstreamDevice)
            guard let service else {
                registerFailure(now: now, message: "network service for en0 not found")
                return
            }
            let result = runner.run("/usr/sbin/networksetup", [
                "-setmanual", service, profile.miniUpstreamAddress,
                profile.miniUpstreamSubnetMask, profile.miniUpstreamRouter
            ])
            guard result.succeeded else {
                registerFailure(now: now, message: result.output)
                return
            }
            status.lastAction = "reapplied en0 manual IPv4 configuration"
            status.lastError = nil
            pendingRepairVerification = true
            addressWaitStarted = nil
            transition(to: .addressRecovering, action: status.lastAction)
            scheduleEvaluation(after: 10)

        case .sharingRecovering(let delay):
            if sharingWaitStarted == nil { sharingWaitStarted = now }
            transition(to: .sharingRecovering)
            scheduleEvaluation(after: delay)

        case .restartSharing:
            let result = relaunchNativeSharing()
            guard result.succeeded else {
                registerFailure(now: now, message: result.output)
                return
            }
            status.lastAction = "relaunched native InternetSharing service"
            status.lastError = nil
            pendingRepairVerification = true
            sharingWaitStarted = nil
            transition(to: .sharingRecovering, action: status.lastAction)
            scheduleEvaluation(after: 10)
        }
    }

    private func registerFailure(now: Date, message: String) {
        status.failureCount += 1
        let delays: [TimeInterval] = [60, 300, 900]
        let delay = delays[min(status.failureCount - 1, delays.count - 1)]
        status.nextRetryAt = iso8601.string(from: now.addingTimeInterval(delay))
        transition(to: .recoveryBackoff, error: message)
        scheduleEvaluation(after: GuardianEvaluationCadence.duringRecoveryBackoff(remaining: delay))
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
            self.log.notice("state=\(self.status.state.rawValue, privacy: .public) carrier=\(self.status.carrierActive) address=\(self.status.addressReady) route=\(self.status.routeReady) sharing=\(self.status.sharingRunning) forwarding=\(self.status.forwardingEnabled) egress=\(self.status.upstreamReachable) action=\(self.status.lastAction ?? "-", privacy: .public) error=\(self.status.lastError ?? "-", privacy: .public)")
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

    private func parseDate(_ string: String?) -> Date? {
        string.flatMap(iso8601.date(from:))
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

    private func relaunchNativeSharing() -> CommandResult {
        var service = runner.run("/bin/launchctl", ["print", "system/com.apple.NetworkSharing"])
        guard service.succeeded else { return service }

        if let pid = NativeSharingProcessIdentity.pid(fromLaunchctlPrint: service.output) {
            let terminated = runner.run("/bin/kill", ["-TERM", String(pid)])
            guard terminated.succeeded else { return terminated }
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.25)
                service = runner.run("/bin/launchctl", ["print", "system/com.apple.NetworkSharing"])
                if service.succeeded,
                   NativeSharingProcessIdentity.isStoppedNativeService(launchctlPrint: service.output) {
                    break
                }
            }
        }

        guard service.succeeded,
              NativeSharingProcessIdentity.isStoppedNativeService(launchctlPrint: service.output) else {
            return CommandResult(status: 1, output: "native InternetSharing did not reach a stopped state")
        }
        return runner.run("/bin/launchctl", ["kickstart", "system/com.apple.NetworkSharing"])
    }

    private func kernelForwardingIsEnabled() -> Bool {
        let result = runner.run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"])
        return result.succeeded && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func boundUpstreamIsReachable() -> Bool {
        profile.probeTargets.contains { target in
            runner.run("/sbin/ping", [
                "-b", profile.miniUpstreamDevice,
                "-S", profile.miniUpstreamAddress,
                "-c", "1", "-W", "700", target
            ]).succeeded
        }
    }

    private func upstreamReachability(at now: Date) -> Bool {
        if let lastUpstreamProbeAt, now.timeIntervalSince(lastUpstreamProbeAt) < 60 {
            return cachedUpstreamReachable
        }
        cachedUpstreamReachable = boundUpstreamIsReachable()
        lastUpstreamProbeAt = now
        return cachedUpstreamReachable
    }

    private func consumeFreshDownstreamEgressFailure(at now: Date) -> Bool {
        guard let raw = try? String(contentsOf: downstreamEgressFailureURL, encoding: .utf8) else {
            return false
        }
        try? FileManager.default.removeItem(at: downstreamEgressFailureURL)
        guard let reportedAt = iso8601.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let age = now.timeIntervalSince(reportedAt)
        return age >= -5 && age <= 60
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
        return devices.contains("bridge0")
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
