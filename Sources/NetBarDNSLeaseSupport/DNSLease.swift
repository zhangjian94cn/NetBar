import Foundation

/// The entire per-service DNS configuration is retained, including automatic provenance,
/// search domains and ordering. A missing DNS protocol configuration means automatic DNS.
public struct DNSSettings: Codable, Equatable {
    public let propertyList: Data?

    public init(configuration: [String: Any]?) throws {
        propertyList = try configuration.map {
            try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
    }

    public func configuration() throws -> [String: Any]? {
        guard let propertyList else { return nil }
        guard let result = try PropertyListSerialization.propertyList(from: propertyList, options: [], format: nil) as? [String: Any] else {
            throw DNSLeaseError.invalidState("Invalid saved DNS configuration")
        }
        return result
    }

    public func managed() throws -> DNSSettings {
        var dictionary = try configuration() ?? [:]
        dictionary["ServerAddresses"] = DNSLease.managedServers
        return try DNSSettings(configuration: dictionary)
    }

    public static func == (lhs: DNSSettings, rhs: DNSSettings) -> Bool {
        guard let left = try? lhs.configuration(), let right = try? rhs.configuration() else {
            return lhs.propertyList == rhs.propertyList
        }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }
}

public struct DNSService: Codable, Equatable {
    public let id: String
    public let name: String
    public let device: String
    public let active: Bool
    public let settings: DNSSettings

    public init(id: String, name: String, device: String, active: Bool, settings: DNSSettings) {
        self.id = id; self.name = name; self.device = device; self.active = active; self.settings = settings
    }
}

/// PID alone is not identity: a later process may reuse the PID after a crash/reboot.
public struct DNSProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let executable: String

    public init(pid: Int32, uid: UInt32, startSeconds: UInt64, startMicroseconds: UInt64, executable: String) {
        self.pid = pid; self.uid = uid; self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds; self.executable = executable
    }
}

public struct DNSInterceptionIdentity: Codable, Equatable {
    public let device: String
    public let interfaceIndex: UInt32
    public init(device: String, interfaceIndex: UInt32) { self.device = device; self.interfaceIndex = interfaceIndex }
}

public struct DNSLease: Codable, Equatable {
    // Match Verge 2.5.8's own Fake-IP TUN placeholder. A second placeholder
    // writer would cause Verge to replace its original DNS backup with ours.
    public static let managedServers = ["114.114.114.114"]
    public static let schemaVersion = 1
    public struct Record: Codable, Equatable {
        public let serviceID: String
        public let device: String
        public let original: DNSSettings
        public let applied: DNSSettings
        public var disposition: Disposition
    }
    public enum Disposition: String, Codable {
        case prepared, owned, restored, conflict
    }
    public let schemaVersion: Int
    public let id: String
    public let owner: DNSProcessIdentity
    public let clash: DNSProcessIdentity
    public let core: DNSProcessIdentity?
    public let createdAt: Date
    public var records: [Record]
    public var interception: DNSInterceptionIdentity?
    public var activationDeadline: Date?
    public var recoveryNotBefore: Date?

    public init(owner: DNSProcessIdentity, clash: DNSProcessIdentity, core: DNSProcessIdentity? = nil) {
        schemaVersion = Self.schemaVersion
        id = UUID().uuidString.lowercased()
        self.owner = owner; self.clash = clash; self.core = core; createdAt = Date(); records = []
    }
}

public struct DNSLeaseStatus: Codable, Equatable {
    public let protocolVersion: Int
    public let dnsLeaseState: String
    public let dnsLeaseOwnerPID: Int32?
    public let dnsLeaseServices: Int
    public let reason: String?

    public init(state: String, owner: Int32? = nil, services: Int = 0, reason: String? = nil) {
        protocolVersion = 7
        dnsLeaseState = state; dnsLeaseOwnerPID = owner; dnsLeaseServices = services; self.reason = reason
    }
}

public enum DNSLeaseError: LocalizedError {
    case invalidState(String)
    case ownerChanged
    case noPhysicalService
    case externalChange(String)
    case writeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidState(let reason), .writeFailed(let reason): return reason
        case .ownerChanged: return "DNS lease belongs to a different NetBar or Clash process; release it first"
        case .noPhysicalService: return "No active physical network service is eligible for temporary DNS"
        case .externalChange(let id): return "DNS changed outside NetBar for service \(id); external settings preserved"
        }
    }
}

public protocol DNSLeaseBackend: AnyObject {
    /// Physical services across locations (so old UUIDs can be restored); only currently
    /// participating services are active. VPN/scoped resolvers are excluded.
    func services() throws -> [DNSService]
    /// Must compare-and-set in the same SCPreferences lock/commit, never overwrite a concurrent edit.
    func replace(serviceID: String, expected: DNSSettings, with settings: DNSSettings) throws
    func isAlive(_ identity: DNSProcessIdentity) -> Bool
    /// Fixed local read-only evidence, never an internet probe or a timer.
    func interceptionIdentity(for lease: DNSLease) -> DNSInterceptionIdentity?
}

public protocol DNSLeaseStoring: AnyObject {
    func load() throws -> DNSLease?
    func save(_ lease: DNSLease) throws
    func finish(_ lease: DNSLease, status: DNSLeaseStatus) throws
    func previousStatus() throws -> DNSLeaseStatus?
    func acknowledgeConflict() throws
}

/// All methods run under the privileged helper's single writer lock. Every change is
/// write-ahead journaled. Recovery does not need a successful acquire/commit return value.
public final class DNSLeaseEngine {
    private let backend: DNSLeaseBackend
    private let store: DNSLeaseStoring
    private let now: () -> Date

    public init(backend: DNSLeaseBackend, store: DNSLeaseStoring, now: @escaping () -> Date = Date.init) {
        self.backend = backend; self.store = store; self.now = now
    }

    public func status() throws -> DNSLeaseStatus {
        guard let lease = try store.load() else {
            guard let previous = try store.previousStatus() else { return .init(state: "inactive") }
            // The receipt's protocol describes its old writer, not this installed
            // component. Keep its facts/reason while advertising our current API.
            return .init(state: previous.dnsLeaseState, owner: previous.dnsLeaseOwnerPID,
                         services: previous.dnsLeaseServices, reason: previous.reason)
        }
        let services = try backend.services()
        if let deadline = lease.activationDeadline {
            let valid = now() < deadline && backend.isAlive(lease.owner) && backend.isAlive(lease.clash) &&
                lease.core.map({ backend.isAlive($0) }) != false && lease.records.filter({ $0.disposition != .restored }).allSatisfy { record in
                    guard record.disposition == .prepared, let current = services.first(where: { $0.id == record.serviceID }) else { return false }
                    return current.settings == record.original || current.settings == record.applied
                }
            return .init(state: valid ? "preparing" : "conflict", owner: lease.owner.pid, services: 0,
                         reason: valid ? "Original DNS saved before native TUN activation; protection not yet verified" : "DNS preparation expired or changed; recovery required")
        }
        let owned = lease.records.filter { record in
            (record.disposition == .owned || record.disposition == .prepared) &&
                services.first(where: { $0.id == record.serviceID })?.settings == record.applied
        }.count
        let processEnded = !backend.isAlive(lease.owner) || !backend.isAlive(lease.clash) ||
            lease.core.map({ !backend.isAlive($0) }) == true
        // Status is observational: an event may not yet have reached the recovery watcher.
        // Never advertise protection from DNS values alone when the bound TUN path is gone.
        let interceptionEnded = !processEnded &&
            (lease.interception == nil || backend.interceptionIdentity(for: lease) != lease.interception)
        let conflicted = processEnded || interceptionEnded ||
            services.filter({ $0.active }).contains { service in
                !lease.records.contains { ($0.disposition == .owned || $0.disposition == .prepared) &&
                    $0.serviceID == service.id && $0.applied == service.settings }
            } || lease.records.contains { record in
            if record.disposition == .conflict { return true }
            guard record.disposition == .owned || record.disposition == .prepared,
                  let service = services.first(where: { $0.id == record.serviceID }) else { return false }
            return service.settings != record.applied && service.settings != record.original
        }
        let reason: String?
        if processEnded { reason = "NetBar, Clash or its core exited; DNS recovery is pending" }
        else if interceptionEnded { reason = "TUN DNS interception ended; protection is inactive and DNS recovery is pending" }
        else if conflicted || owned == 0 { reason = "External DNS changes preserved; release DNS to finish recovery" }
        else { reason = nil }
        return .init(state: conflicted || owned == 0 ? "conflict" : "owned", owner: lease.owner.pid, services: owned,
                     reason: reason)
    }

    /// Journal originals before Verge can write its own TUN placeholder. This action
    /// never edits system DNS; repeated preparation never replaces the first originals.
    public func prepare(owner: DNSProcessIdentity, clash: DNSProcessIdentity, core: DNSProcessIdentity? = nil) throws -> DNSLeaseStatus {
        let prior = try store.load()
        if prior == nil, try store.previousStatus()?.dnsLeaseState == "conflict" {
            throw DNSLeaseError.invalidState("Acknowledge the previous DNS conflict with explicit release before reacquisition")
        }
        if let prior, prior.owner != owner || prior.clash != clash || prior.core != core { throw DNSLeaseError.ownerChanged }
        guard backend.isAlive(owner), backend.isAlive(clash), core.map({ backend.isAlive($0) }) != false else { throw DNSLeaseError.ownerChanged }
        if var prior {
            let current = try status()
            guard ["preparing", "owned"].contains(current.dnsLeaseState) else { throw DNSLeaseError.invalidState("Existing DNS lease requires recovery") }
            if current.dnsLeaseState == "preparing" { return current }
            prior.activationDeadline = now().addingTimeInterval(120)
            prior.interception = nil
            for index in prior.records.indices where prior.records[index].disposition == .owned {
                prior.records[index].disposition = .prepared
            }
            try store.save(prior)
            return try status()
        }
        let services = try backend.services().filter(\.active)
        guard !services.isEmpty else { throw DNSLeaseError.noPhysicalService }
        guard try services.allSatisfy({ try $0.settings.configuration()?["ServerAddresses"] as? [String] != DNSLease.managedServers }) else {
            throw DNSLeaseError.invalidState("Clash placeholder already active without original DNS journal; select original network first")
        }
        var lease = DNSLease(owner: owner, clash: clash, core: core)
        lease.activationDeadline = now().addingTimeInterval(120)
        lease.records = try services.map {
            .init(serviceID: $0.id, device: $0.device, original: $0.settings, applied: try $0.settings.managed(), disposition: .prepared)
        }
        try store.save(lease)
        return try status()
    }

    public func acquire(owner: DNSProcessIdentity, clash: DNSProcessIdentity, core: DNSProcessIdentity? = nil) throws -> DNSLeaseStatus {
        guard var lease = try store.load() else { throw DNSLeaseError.invalidState("Prepare original DNS before native TUN activation") }
        guard lease.owner == owner, lease.clash == clash, lease.core == core,
              backend.isAlive(owner), backend.isAlive(clash), core.map({ backend.isAlive($0) }) != false else { throw DNSLeaseError.ownerChanged }
        let preparing = lease.activationDeadline != nil
        if let deadline = lease.activationDeadline, now() >= deadline {
            throw DNSLeaseError.invalidState("DNS preparation expired; select the mode again")
        }
        guard let interception = backend.interceptionIdentity(for: lease),
              lease.interception == nil || lease.interception == interception else {
            throw DNSLeaseError.invalidState("TUN DNS interception is unavailable; temporary DNS was not acquired")
        }
        lease.interception = interception
        guard !lease.records.contains(where: { $0.disposition == .conflict }) else {
            throw DNSLeaseError.invalidState("External DNS conflict requires explicit release before reacquisition")
        }
        let services = try backend.services()
        guard services.contains(where: { $0.active }) else { throw DNSLeaseError.noPhysicalService }
        if preparing, Set(services.filter(\.active).map(\.id)) != Set(lease.records.filter({ $0.disposition == .prepared }).map(\.serviceID)) {
            throw DNSLeaseError.invalidState("Physical services changed during preparation; restore and select the mode again")
        }
        // Save the lease before touching any service. Repeated mode clicks retain first originals.
        try store.save(lease)
        do {
            for service in services where service.active {
                if let index = lease.records.firstIndex(where: { $0.serviceID == service.id && $0.disposition != .restored }) {
                    let record = lease.records[index]
                    guard record.applied == service.settings || (preparing && record.original == service.settings) else {
                        lease.records[index].disposition = .conflict
                        try store.save(lease)
                        throw DNSLeaseError.externalChange(service.id)
                    }
                    if record.applied != service.settings {
                        try backend.replace(serviceID: service.id, expected: record.original, with: record.applied)
                    }
                    lease.records[index].disposition = .owned
                    try store.save(lease)
                    continue
                }
                guard try service.settings.configuration()?["ServerAddresses"] as? [String] != DNSLease.managedServers else {
                    throw DNSLeaseError.invalidState("New service already has Clash placeholder DNS; original settings are unknown, manual recovery required")
                }
                let applied = try service.settings.managed()
                let record = DNSLease.Record(serviceID: service.id, device: service.device, original: service.settings,
                                             applied: applied, disposition: .prepared)
                let index: Int
                if let restored = lease.records.firstIndex(where: { $0.serviceID == service.id }) {
                    index = restored; lease.records[index] = record
                } else {
                    index = lease.records.count; lease.records.append(record)
                }
                try store.save(lease)
                try backend.replace(serviceID: service.id, expected: service.settings, with: applied)
                lease.records[index].disposition = .owned
                try store.save(lease)
            }
            lease.activationDeadline = nil
            try store.save(lease)
            return try status()
        } catch {
            // Keep originals journaled until the app finishes its native rollback, then
            // releases DNS. The already-running Guardian covers crash/deadline recovery.
            throw error
        }
    }

    /// Reconcile while owner lives: release inactive services and adopt newly active physical
    /// services. A network event never changes the owner's mode, Clash state, or VPN.
    public func reconcile() throws -> DNSLeaseStatus {
        guard var lease = try store.load() else { return try status() }
        let processesAlive = backend.isAlive(lease.owner) && backend.isAlive(lease.clash) && lease.core.map({ backend.isAlive($0) }) != false
        if !processesAlive, lease.activationDeadline != nil {
            // Verge bounds its native DNS script at five seconds. Let an already
            // dispatched script settle before restoring after a mid-switch crash.
            if lease.recoveryNotBefore == nil {
                lease.recoveryNotBefore = now().addingTimeInterval(6)
                try store.save(lease)
            }
            if now() < lease.recoveryNotBefore! { return try status() }
        }
        guard processesAlive else {
            return try release(reason: "NetBar, Clash or its core exited; DNS restored")
        }
        if let deadline = lease.activationDeadline {
            if now() >= deadline {
                if lease.recoveryNotBefore == nil {
                    lease.recoveryNotBefore = now().addingTimeInterval(6)
                    try store.save(lease)
                }
                if now() >= lease.recoveryNotBefore! { return try release(reason: "DNS preparation expired; originals restored") }
            }
            return try status()
        }
        guard let interception = backend.interceptionIdentity(for: lease), lease.interception == interception else {
            return try release(reason: "TUN DNS interception ended; DNS restored")
        }
        let services = try backend.services()
        for index in lease.records.indices where lease.records[index].disposition == .owned || lease.records[index].disposition == .prepared {
            let record = lease.records[index]
            guard let current = services.first(where: { $0.id == record.serviceID }) else {
                // A removed service cannot be safely rewritten in a different network location.
                // Keep its UUID-bound record for later recovery, rather than use a reused name.
                continue
            }
            if current.settings != record.applied {
                // Returning to the original values may itself be a deliberate external
                // edit. Never interpret it as permission to acquire the service again.
                lease.records[index].disposition = .conflict
                try store.save(lease)
            } else if !current.active {
                try backend.replace(serviceID: record.serviceID, expected: record.applied, with: record.original)
                lease.records[index].disposition = .restored
                try store.save(lease)
            }
        }
        if lease.records.contains(where: { $0.disposition == .conflict }) { return try status() }
        return try acquire(owner: lease.owner, clash: lease.clash, core: lease.core)
    }

    @discardableResult
    public func release(reason: String? = nil) throws -> DNSLeaseStatus {
        guard var lease = try store.load() else {
            if try store.previousStatus()?.dnsLeaseState == "conflict" {
                // Explicit release can acknowledge a completed conflict. Historical receipts
                // remain; no DNS settings change and managed modes never do this implicitly.
                try store.acknowledgeConflict()
                return .init(state: "inactive", reason: "External DNS settings preserved; previous conflict acknowledged")
            }
            return try status()
        }
        let services = try backend.services()
        var unresolved = false
        for index in lease.records.indices {
            let record = lease.records[index]
            guard record.disposition == .owned || record.disposition == .prepared else { continue }
            guard let service = services.first(where: { $0.id == record.serviceID }) else {
                unresolved = true; continue
            }
            if service.settings == record.original {
                lease.records[index].disposition = .restored
            } else if service.settings == record.applied {
                do {
                    try backend.replace(serviceID: record.serviceID, expected: record.applied, with: record.original)
                    lease.records[index].disposition = .restored
                } catch {
                    // Preserve write-ahead record for a later bounded retry/manual recovery.
                    unresolved = true
                }
            } else {
                lease.records[index].disposition = .conflict
            }
            try store.save(lease)
        }
        let conflict = unresolved || lease.records.contains { $0.disposition == .conflict }
        let result = DNSLeaseStatus(state: conflict ? "conflict" : "inactive",
                                    owner: unresolved ? lease.owner.pid : nil,
                                    services: lease.records.filter { $0.disposition == .owned || $0.disposition == .prepared }.count,
                                    reason: conflict ? "manual_pending: external DNS preserved or service unavailable; retry release when service is available" : reason)
        if !unresolved { try store.finish(lease, status: result) }
        return result
    }
}
