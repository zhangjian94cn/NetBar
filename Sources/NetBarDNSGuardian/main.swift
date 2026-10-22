import CryptoKit
import Darwin
import Foundation
import NetBarDNSLeaseSupport
import NetworkExecution
import SystemConfiguration

private let stateRoot = URL(fileURLWithPath: "/Library/Application Support/NetBar/RouteSafety", isDirectory: true)
private let guardianLabel = "com.zjah.NetBarDNSGuardian"

private func fail(_ text: String) -> Never {
    let result = DNSLeaseStatus(state: "conflict", reason: "manual_pending: \(text)")
    if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data); print("") }
    exit(1)
}

private func checkRootPath(_ url: URL, directory: Bool, privateMode: Bool = false) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
          info.st_uid == 0,
          (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
          info.st_mode & 0o022 == 0,
          !privateMode || info.st_mode & 0o077 == 0 else {
        throw DNSLeaseError.invalidState("Unsafe privileged DNS state path")
    }
}

private func prepareStateRoot() throws {
    for path in ["/Library", "/Library/Application Support", "/Library/Application Support/NetBar"] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o755])
        }
        try checkRootPath(url, directory: true)
    }
    if !FileManager.default.fileExists(atPath: stateRoot.path) {
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    try checkRootPath(stateRoot, directory: true, privateMode: true)
}

private final class PrivilegedLock {
    private var descriptor: Int32 = -1
    init() throws {
        let url = stateRoot.appendingPathComponent("execution.lock")
        descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DNSLeaseError.invalidState("Cannot open DNS writer lock") }
        var info = stat()
        var lock = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, fcntl(descriptor, F_SETLK, &lock) == 0 else {
            close(descriptor); descriptor = -1
            throw DNSLeaseError.invalidState("Helper busy; retry after the current transaction")
        }
    }
    deinit { if descriptor >= 0 { close(descriptor) } } // POSIX lock matches zsystem flock.
}

private final class LeaseStore: DNSLeaseStoring {
    private struct Envelope: Codable { let lease: DNSLease; let sha256: String }
    private let encoder: JSONEncoder = { let result = JSONEncoder(); result.outputFormatting = [.sortedKeys]; return result }()
    private let leaseURL = stateRoot.appendingPathComponent("dns-lease.json")
    private let outcomeURL = stateRoot.appendingPathComponent("dns-outcome.json")

    private func digest(_ lease: DNSLease) throws -> String {
        SHA256.hash(data: try encoder.encode(lease)).map { String(format: "%02x", $0) }.joined()
    }
    private func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DNSLeaseError.invalidState("Cannot sync DNS recovery journal") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw DNSLeaseError.invalidState("Cannot persist DNS recovery journal") }
    }
    func load() throws -> DNSLease? {
        guard FileManager.default.fileExists(atPath: leaseURL.path) else { return nil }
        try checkRootPath(leaseURL, directory: false, privateMode: true)
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: leaseURL))
        guard envelope.lease.schemaVersion == DNSLease.schemaVersion,
              try digest(envelope.lease) == envelope.sha256,
              envelope.lease.records.count <= 64,
              envelope.lease.records.allSatisfy({ UUID(uuidString: $0.serviceID) != nil }) else {
            throw DNSLeaseError.invalidState("DNS lease schema or checksum mismatch")
        }
        return envelope.lease
    }
    func save(_ lease: DNSLease) throws {
        if FileManager.default.fileExists(atPath: leaseURL.path) {
            try checkRootPath(leaseURL, directory: false, privateMode: true)
        }
        try encoder.encode(Envelope(lease: lease, sha256: digest(lease))).write(to: leaseURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leaseURL.path)
        try sync(leaseURL)
    }
    func finish(_ lease: DNSLease, status: DNSLeaseStatus) throws {
        let history = stateRoot.appendingPathComponent("DNSHistory", isDirectory: true)
        if !FileManager.default.fileExists(atPath: history.path) {
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try checkRootPath(history, directory: true, privateMode: true)
        let archive = history.appendingPathComponent("\(lease.id).json")
        guard UUID(uuidString: lease.id) != nil else { throw DNSLeaseError.invalidState("Invalid lease ID") }
        try encoder.encode(Envelope(lease: lease, sha256: digest(lease))).write(to: archive, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        if FileManager.default.fileExists(atPath: outcomeURL.path) { try checkRootPath(outcomeURL, directory: false, privateMode: true) }
        try encoder.encode(status).write(to: outcomeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outcomeURL.path)
        try checkRootPath(leaseURL, directory: false, privateMode: true)
        try FileManager.default.removeItem(at: leaseURL)
    }
    func previousStatus() throws -> DNSLeaseStatus? {
        guard FileManager.default.fileExists(atPath: outcomeURL.path) else { return nil }
        try checkRootPath(outcomeURL, directory: false, privateMode: true)
        return try JSONDecoder().decode(DNSLeaseStatus.self, from: Data(contentsOf: outcomeURL))
    }
    func acknowledgeConflict() throws {
        guard try load() == nil else { throw DNSLeaseError.invalidState("Active DNS lease still requires recovery") }
        if FileManager.default.fileExists(atPath: outcomeURL.path) {
            try checkRootPath(outcomeURL, directory: false, privateMode: true)
            try encoder.encode(DNSLeaseStatus(state: "inactive", reason: "Previous conflict acknowledged; external DNS preserved"))
                .write(to: outcomeURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outcomeURL.path)
        }
    }
}

private func processIdentity(_ pid: pid_t) -> DNSProcessIdentity? {
    var info = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return DNSProcessIdentity(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                              startMicroseconds: info.pbi_start_tvusec, executable: String(cString: path))
}

private final class MacDNSBackend: DNSLeaseBackend {
    func isAlive(_ identity: DNSProcessIdentity) -> Bool { processIdentity(identity.pid) == identity }

    func interceptionIdentity(for lease: DNSLease) -> DNSInterceptionIdentity? {
        guard lease.core.map({ isAlive($0) }) == true else { return nil }
        let socket = "/var/run/clash-verge-service/users/\(lease.owner.uid)/verge-mihomo.sock"
        var info = stat()
        guard lstat(socket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == lease.owner.uid || info.st_uid == 0 else { return nil }
        let response = BoundedCommand.run("/usr/bin/curl", ["-q", "--silent", "--show-error", "--fail", "--noproxy", "*",
            "--max-time", "2", "--unix-socket", socket, "http://localhost/configs"], timeout: 2.5, outputLimit: 65_536)
        guard response.exitCode == 0, !response.outputTruncated,
              let dictionary = try? JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [String: Any],
              let tun = dictionary["tun"] as? [String: Any], tun["enable"] as? Bool == true,
              let device = tun["device"] as? String,
              device.range(of: "^utun[0-9]+$", options: .regularExpression) != nil,
              let hijacks = tun["dns-hijack"] as? [String],
              hijacks.contains("any:53") || hijacks.contains("udp://any:53"),
              hijacks.contains("tcp://any:53") else { return nil }
        let index = if_nametoindex(device)
        guard index != 0 else { return nil }
        for server in DNSLease.managedServers {
            let route = BoundedCommand.run("/sbin/route", ["-n", "get", "-inet", server], timeout: 1, outputLimit: 8_192)
            let routedDevice = route.stdout.split(separator: "\n").compactMap { line -> String? in
                let pieces = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return pieces.count == 2 && pieces[0] == "interface" ? pieces[1] : nil
            }.first
            guard route.exitCode == 0, !route.outputTruncated, routedDevice == device,
                  if_nametoindex(device) == index else { return nil }
        }
        return .init(device: device, interfaceIndex: index)
    }

    func services() throws -> [DNSService] {
        guard let prefs = SCPreferencesCreate(nil, "NetBar DNS lease" as CFString, nil),
              let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService],
              let current = SCNetworkSetCopyCurrent(prefs),
              let currentServices = SCNetworkSetCopyServices(current) as? [SCNetworkService],
              let dynamic = SCDynamicStoreCreate(nil, "NetBar DNS lease read" as CFString, nil, nil) else {
            throw DNSLeaseError.invalidState("Cannot enumerate current network services")
        }
        let currentIDs = Set(currentServices.compactMap { SCNetworkServiceGetServiceID($0) as String? })
        return try all.compactMap { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let name = SCNetworkServiceGetName(service) as String?,
                  let device = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  [kSCNetworkInterfaceTypeEthernet as String, kSCNetworkInterfaceTypeIEEE80211 as String,
                   "Bridge"].contains(type),
                  device == "bridge0" || device.range(of: "^en[0-9]+$", options: .regularExpression) != nil,
                  let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS),
                  SCNetworkProtocolGetEnabled(dns),
                  let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            let configuration = SCNetworkProtocolGetConfiguration(dns) as? [String: Any]
            // Scoped/supplemental resolvers belong to VPN/Tailscale, never this helper.
            guard configuration?["SupplementalMatchDomains"] == nil,
                  configuration?["SupplementalMatchDomainsNoSearch"] == nil else { return nil }
            let ipv4 = SCDynamicStoreCopyValue(dynamic, "State:/Network/Service/\(id)/IPv4" as CFString) as? [String: Any]
            let ipv6 = SCDynamicStoreCopyValue(dynamic, "State:/Network/Service/\(id)/IPv6" as CFString) as? [String: Any]
            let link = SCDynamicStoreCopyValue(dynamic, "State:/Network/Interface/\(device)/Link" as CFString) as? [String: Any]
            let hasAddress = !(ipv4?["Addresses"] as? [String] ?? []).isEmpty || !(ipv6?["Addresses"] as? [String] ?? []).isEmpty
            let hasRouter = !(ipv4?["Router"] as? String ?? "").isEmpty || !(ipv6?["Router"] as? String ?? "").isEmpty
            // The Mini management /30 alone is not an internet-participating service.
            let participates = hasAddress && hasRouter && (link?["Active"] as? Bool != false)
            return DNSService(id: id, name: name, device: device, active: SCNetworkServiceGetEnabled(service) && currentIDs.contains(id) && participates,
                              settings: try DNSSettings(configuration: configuration))
        }
    }

    func replace(serviceID: String, expected: DNSSettings, with settings: DNSSettings) throws {
        guard UUID(uuidString: serviceID) != nil,
              let prefs = SCPreferencesCreate(nil, "NetBar temporary DNS" as CFString, nil),
              SCPreferencesLock(prefs, false) else { throw DNSLeaseError.writeFailed("Network preferences busy") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        guard let service = SCNetworkServiceCopy(prefs, serviceID as CFString),
              let interface = SCNetworkServiceGetInterface(service),
              let device = SCNetworkInterfaceGetBSDName(interface) as String?,
              device == "bridge0" || device.range(of: "^en[0-9]+$", options: .regularExpression) != nil,
              let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
            throw DNSLeaseError.writeFailed("Physical network service no longer exists")
        }
        let current = try DNSSettings(configuration: SCNetworkProtocolGetConfiguration(dns) as? [String: Any])
        guard current == expected else { throw DNSLeaseError.externalChange(serviceID) }
        let configuration = try settings.configuration()
        guard SCNetworkProtocolSetConfiguration(dns, configuration as CFDictionary?),
              SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw DNSLeaseError.writeFailed("System DNS commit/apply failed")
        }
        // Read a fresh preferences session: commit success alone does not prove readback.
        guard let after = try services().first(where: { $0.id == serviceID }), after.settings == settings else {
            throw DNSLeaseError.writeFailed("System DNS readback did not match")
        }
    }
}

private func consoleProcesses() throws -> (DNSProcessIdentity, DNSProcessIdentity, DNSProcessIdentity) {
    var consoleUID: uid_t = 0
    guard let consoleName = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) as String?,
          consoleUID >= 500, consoleName != "loginwindow", let account = getpwuid(consoleUID) else {
        throw DNSLeaseError.invalidState("No verified local console user")
    }
    let userHome = String(cString: account.pointee.pw_dir)
    let allowedNetBar = Set(["\(userHome)/Applications/NetBar.app/Contents/MacOS/NetBar", "/Applications/NetBar.app/Contents/MacOS/NetBar"])
    // libproc works in the launchd system session without connecting to WindowServer.
    let count = proc_listallpids(nil, 0)
    guard count > 0, count < 100_000 else { throw DNSLeaseError.invalidState("Cannot enumerate owner processes") }
    var pids = [pid_t](repeating: 0, count: Int(count) + 128)
    let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard actual > 0 else { throw DNSLeaseError.invalidState("Cannot verify owner processes") }
    let identities = pids.prefix(Int(actual)).filter { $0 > 0 }.compactMap { processIdentity($0) }
    let netbars = identities.filter { $0.uid == consoleUID && allowedNetBar.contains($0.executable) }
    let allowedClash = Set(["/Applications/Clash Verge.app/Contents/MacOS/clash-verge", "\(userHome)/Applications/Clash Verge.app/Contents/MacOS/clash-verge"])
    let allowedCore = Set(["/Library/Application Support/clash-verge-service/cores/verge-mihomo", "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo", "\(userHome)/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"])
    let clashes = identities.filter { $0.uid == consoleUID && allowedClash.contains($0.executable) }
    let cores = identities.filter { ($0.uid == consoleUID || $0.uid == 0) && allowedCore.contains($0.executable) }
    guard netbars.count == 1, clashes.count == 1, cores.count == 1 else {
        throw DNSLeaseError.invalidState("Exactly one installed NetBar, Clash Verge and Mihomo core is required")
    }
    return (netbars[0], clashes[0], cores[0])
}

private func launchctl(_ args: [String]) throws {
    // launchd may honor the job's 30-second throttle after an idle exit. A
    // three-second client deadline mistakes that valid delay for a bad install.
    let starting = args.first == "kickstart"
    let result = BoundedCommand.run("/bin/launchctl", args, timeout: starting ? 35 : 3, outputLimit: 16_384)
    guard result.exitCode == 0, !result.outputTruncated else {
        throw DNSLeaseError.invalidState(result.outcome == .timedOut
            ? "DNS recovery launchd request timed out; network changes were not committed"
            : "DNS recovery launchd request failed; verify the installed recovery component")
    }
    if starting {
        guard let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              let identity = processIdentity(pid), identity.uid == 0,
              identity.executable == "/Library/PrivilegedHelperTools/com.zjah.NetBarDNSGuardian" else {
            throw DNSLeaseError.invalidState("DNS recovery process did not match the installed component")
        }
    }
}

private func printStatus(_ status: DNSLeaseStatus) throws {
    FileHandle.standardOutput.write(try JSONEncoder().encode(status)); print("")
}

private final class Watcher {
    private let queue = DispatchQueue(label: "com.zjah.NetBar.dns-guardian", qos: .utility)
    private var sources: [DispatchSourceProcess] = []
    private var dynamic: SCDynamicStore?
    private var work: DispatchWorkItem?
    private var retries = 0
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var filePaths: [String] = []
    private var preparationTimer: DispatchWorkItem?
    private var observedLease: DNSLease?
    private let leasePath = stateRoot.appendingPathComponent("dns-lease.json").path

    func start() throws -> Never {
        let store = LeaseStore()
        guard let lease = try store.load() else { exit(0) }
        refreshObservation(lease)
        if let account = getpwuid(lease.owner.uid) {
            let config = String(cString: account.pointee.pw_dir) + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/"
            filePaths = ["verge.yaml", "config.yaml", "clash-verge.yaml"].map { config + $0 }
            for path in filePaths { watchFile(path) }
        }
        watchFile(leasePath)
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        dynamic = SCDynamicStoreCreate(nil, "NetBar DNS recovery" as CFString, { _, _, context in
            guard let context else { return }
            Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().schedule()
        }, &context)
        guard let dynamic, SCDynamicStoreSetNotificationKeys(dynamic, nil, [
            "State:/Network/Service/.*/IPv4", "State:/Network/Service/.*/IPv6", "Setup:/Network/Service/.*/DNS",
            "Setup:/Network/Global/IPv4", "State:/Network/Global/(IPv4|IPv6|DNS)",
            "State:/Network/Interface/.*/(IPv4|IPv6|Link)"
        ] as CFArray), SCDynamicStoreSetDispatchQueue(dynamic, queue) else {
            throw DNSLeaseError.invalidState("Cannot watch network changes for DNS recovery")
        }
        schedule()
        withExtendedLifetime(self) { dispatchMain() }
    }

    private func watchFile(_ path: String) {
        guard fileSources[path] == nil else { return }
        let fd = open(path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let source, !source.data.intersection([.delete, .rename]).isEmpty {
                self.fileSources.removeValue(forKey: path)?.cancel()
            }
            if path == self.leasePath {
                self.watchFile(path)
                // Reconcile writes the journal too. Ignore our own final value
                // rather than turn an atomic write into a perpetual event loop.
                do {
                    let current = try LeaseStore().load()
                    if current == self.observedLease { return }
                } catch { /* A real journal error still needs bounded recovery. */ }
            }
            self.schedule()
        }
        fileSources[path] = source; source.resume()
    }

    private func schedule() {
        work?.cancel()
        retries = 0
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        work = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    private func schedulePreparationDeadline(_ lease: DNSLease) {
        preparationTimer?.cancel(); preparationTimer = nil
        guard let deadline = lease.recoveryNotBefore ?? lease.activationDeadline else { return }
        let timer = DispatchWorkItem { [weak self] in self?.reconcile() }
        preparationTimer = timer
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timer)
    }
    private func refreshObservation(_ lease: DNSLease) {
        if observedLease?.owner != lease.owner || observedLease?.clash != lease.clash || observedLease?.core != lease.core {
            sources.forEach { $0.cancel() }; sources.removeAll()
            for identity in [lease.owner, lease.clash] + (lease.core.map { [$0] } ?? []) {
                if let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: queue) as DispatchSourceProcess? {
                    source.setEventHandler { [weak self] in self?.schedule() }; source.resume(); sources.append(source)
                }
            }
        }
        observedLease = lease
        schedulePreparationDeadline(lease)
    }
    private func reconcile() {
        do {
            let lock = try PrivilegedLock()
            defer { withExtendedLifetime(lock) {} }
            let store = LeaseStore()
            guard try store.load() != nil else { exit(0) }
            watchFile(leasePath)
            for path in filePaths { watchFile(path) }
            let result = try DNSLeaseEngine(backend: MacDNSBackend(), store: store).reconcile()
            retries = 0
            try printStatus(result)
            guard let remaining = try store.load() else { exit(0) }
            refreshObservation(remaining)
        } catch {
            // Bounded contention retry, never a network-probe loop. Future network events
            // can retry unresolved services; a writer lock may still be finishing acquire.
            fputs("NetBar DNS recovery: \(error.localizedDescription)\n", stderr)
            guard retries < 5 else { return } // Next genuine process/network event may retry.
            let delay = pow(2.0, Double(retries)); retries += 1
            let item = DispatchWorkItem { [weak self] in self?.reconcile() }
            work = item; queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
}

umask(0o077)
guard geteuid() == 0, CommandLine.arguments.count == 2 else { fail("Root helper accepts one fixed action") }
do {
    try prepareStateRoot()
    let action = CommandLine.arguments[1]
    guard ["dns-status", "dns-prepare", "dns-acquire", "dns-release", "dns-reconcile", "watch"].contains(action) else { fail("Unsupported DNS action") }
    if action == "watch" { try Watcher().start() }
    let lock = try PrivilegedLock()
    defer { withExtendedLifetime(lock) {} }
    let store = LeaseStore()
    let engine = DNSLeaseEngine(backend: MacDNSBackend(), store: store)
    switch action {
    case "dns-status": try printStatus(engine.status())
    case "dns-release":
        // The native rollback can dispatch Verge's bounded five-second DNS script.
        // Hold our writer lock until it settles, then compare-and-set originals.
        if try store.load()?.activationDeadline != nil { Thread.sleep(forTimeInterval: 6) }
        try printStatus(engine.release(reason: "DNS restored by user action"))
    case "dns-reconcile": try printStatus(engine.reconcile())
    case "dns-prepare", "dns-acquire":
        guard !FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("dns-installing").path) else {
            throw DNSLeaseError.invalidState("DNS recovery component installation is in progress")
        }
        guard !FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("pending-kind.txt").path) else {
            throw DNSLeaseError.invalidState("Finish existing Route Safety transaction before acquiring DNS")
        }
        try launchctl(["print", "system/\(guardianLabel)"])
        let (owner, clash, core) = try consoleProcesses()
        let prepared = action == "dns-prepare" ? try engine.prepare(owner: owner, clash: clash, core: core) : nil
        // An existing watcher observes atomic lease updates itself. Do not kill
        // the recovery safety net on every prepare/acquire operation.
        // A launch failure retains the original journal. The app must roll back
        // native Clash first, then release DNS; launchd also still sees the lease.
        try launchctl(["kickstart", "-p", "system/\(guardianLabel)"])
        let result = try prepared ?? engine.acquire(owner: owner, clash: clash, core: core)
        try printStatus(result)
    default: break
    }
} catch { fail(error.localizedDescription) }
