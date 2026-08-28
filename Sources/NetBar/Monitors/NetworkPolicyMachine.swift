import Foundation

enum NetworkPolicyIntent: String, Codable, Equatable {
    case miniPreferred
    case wifiPreferred
}

enum ObservedUnderlay: String, Codable, Equatable {
    case mini
    case wifi
    case none
    case ambiguous
}

enum NetworkProofFailure: String, Codable, Equatable {
    case linkUnavailable
    case miniUpstreamUnavailable
    case sharingUnavailable
    case downstreamEgressUnavailable
    case wifiUnavailable
    case overlayUnavailable
    case evidenceConflict
}

enum CandidateProof: Codable, Equatable {
    case unknown
    case unavailable(NetworkProofFailure)
    case preflightEligible
    case activeVerified

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum NetworkTransitionPhase: Codable, Equatable {
    case observing
    case qualifying(ObservedUnderlay)
    case switching(transactionID: String, target: ObservedUnderlay)
    case rebindingMihomo(transactionID: String)
    case verifying(transactionID: String, target: ObservedUnderlay)
    case rollingBack(transactionID: String)
    case waitingForRecovery
    case circuitOpen(until: Date)
    case manualRecovery

    var hasPendingTransaction: Bool {
        switch self {
        case .switching, .rebindingMihomo, .verifying, .rollingBack:
            return true
        default:
            return false
        }
    }
}

struct NetworkPolicyState: Equatable {
    var intent: NetworkPolicyIntent
    var generation: UInt64
    var observedUnderlay: ObservedUnderlay
    var miniProof: CandidateProof
    var wifiProof: CandidateProof
    var phase: NetworkTransitionPhase
    var miniQualifiedSince: Date?
    var degradationStartedAt: Date?
    var nextTransactionSequence: UInt64

    static let initial = NetworkPolicyState(
        intent: .miniPreferred,
        generation: 0,
        observedUnderlay: .none,
        miniProof: .unknown,
        wifiProof: .unknown,
        phase: .observing,
        miniQualifiedSince: nil,
        degradationStartedAt: nil,
        nextTransactionSequence: 0
    )
}

enum NetworkPolicyEvent: Equatable {
    case preferenceChanged(NetworkPolicyIntent, at: Date)
    case evidence(
        generation: UInt64,
        observedUnderlay: ObservedUnderlay,
        mini: CandidateProof,
        wifi: CandidateProof,
        at: Date
    )
    case routeApplied(generation: UInt64, transactionID: String, target: ObservedUnderlay, at: Date)
    case mihomoRebound(generation: UInt64, transactionID: String, succeeded: Bool, at: Date)
    case verified(generation: UInt64, transactionID: String, target: ObservedUnderlay, succeeded: Bool, at: Date)
    case rolledBack(generation: UInt64, transactionID: String, succeeded: Bool, at: Date)
}

enum NetworkPolicyEffect: Equatable {
    case switchRoute(transactionID: String, target: ObservedUnderlay, deadline: Date, idempotencyKey: String)
    case rebindMihomo(transactionID: String, deadline: Date, idempotencyKey: String)
    case verify(transactionID: String, target: ObservedUnderlay, deadline: Date)
    case commit(transactionID: String)
    case rollback(transactionID: String, deadline: Date)
    case record(String)
}

enum NetworkPolicyMachine {
    static func reduce(
        state original: NetworkPolicyState,
        event: NetworkPolicyEvent
    ) -> (state: NetworkPolicyState, effects: [NetworkPolicyEffect]) {
        var state = original

        switch event {
        case .preferenceChanged(let intent, let now):
            state.intent = intent
            state.miniQualifiedSince = nil
            guard !state.phase.hasPendingTransaction else { return (state, []) }
            return decide(state: state, now: now)

        case .evidence(let generation, let underlay, let mini, let wifi, let now):
            guard generation >= state.generation else { return (original, []) }
            if generation > state.generation {
                state.generation = generation
                if state.phase.hasPendingTransaction {
                    state.phase = .observing
                }
            }
            state.observedUnderlay = underlay
            state.miniProof = mini
            state.wifiProof = wifi
            return decide(state: state, now: now)

        case .routeApplied(let generation, let transactionID, let target, let now):
            guard generation == state.generation,
                  state.phase == .switching(transactionID: transactionID, target: target) else {
                return (original, [])
            }
            state.phase = .rebindingMihomo(transactionID: transactionID)
            return (state, [.rebindMihomo(
                transactionID: transactionID,
                deadline: now.addingTimeInterval(10),
                idempotencyKey: "underlay:\(state.generation):\(state.observedUnderlay.rawValue):\(target.rawValue)"
            )])

        case .mihomoRebound(let generation, let transactionID, _, let now):
            guard generation == state.generation,
                  state.phase == .rebindingMihomo(transactionID: transactionID) else {
                return (original, [])
            }
            let target = transactionTarget(transactionID: transactionID) ?? preferredTarget(state.intent)
            state.phase = .verifying(transactionID: transactionID, target: target)
            return (state, [.verify(
                transactionID: transactionID,
                target: target,
                deadline: now.addingTimeInterval(10)
            )])

        case .verified(let generation, let transactionID, let target, let succeeded, let now):
            guard generation == state.generation,
                  state.phase == .verifying(transactionID: transactionID, target: target) else {
                return (original, [])
            }
            if succeeded {
                state.phase = .observing
                state.observedUnderlay = target
                if target == .mini { state.degradationStartedAt = nil }
                return (state, [.commit(transactionID: transactionID)])
            }
            state.phase = .rollingBack(transactionID: transactionID)
            return (state, [.rollback(transactionID: transactionID, deadline: now.addingTimeInterval(10))])

        case .rolledBack(let generation, let transactionID, let succeeded, _):
            guard generation == state.generation,
                  state.phase == .rollingBack(transactionID: transactionID) else {
                return (original, [])
            }
            state.phase = succeeded ? .waitingForRecovery : .manualRecovery
            return (state, [.record(succeeded ? "route_rollback_succeeded" : "manual_recovery_required")])
        }
    }

    private static func decide(
        state original: NetworkPolicyState,
        now: Date
    ) -> (state: NetworkPolicyState, effects: [NetworkPolicyEffect]) {
        var state = original
        guard !state.phase.hasPendingTransaction else { return (state, []) }
        if case .manualRecovery = state.phase { return (state, []) }
        if case .circuitOpen(let until) = state.phase, until > now { return (state, []) }

        if state.intent == .wifiPreferred {
            state.miniQualifiedSince = nil
            guard state.observedUnderlay != .wifi,
                  state.wifiProof == .activeVerified || state.wifiProof == .preflightEligible else {
                state.phase = state.wifiProof.isUnavailable ? .waitingForRecovery : .observing
                return (state, [])
            }
            return beginSwitch(state: state, target: .wifi, now: now)
        }

        if state.observedUnderlay == .mini, state.miniProof == .activeVerified {
            state.phase = .observing
            state.miniQualifiedSince = nil
            state.degradationStartedAt = nil
            return (state, [])
        }

        if state.miniProof.isUnavailable {
            if state.degradationStartedAt == nil { state.degradationStartedAt = now }
            state.miniQualifiedSince = nil
            guard state.observedUnderlay != .wifi,
                  state.wifiProof == .activeVerified || state.wifiProof == .preflightEligible else {
                state.phase = .waitingForRecovery
                return (state, [])
            }
            return beginSwitch(state: state, target: .wifi, now: now)
        }

        guard state.miniProof == .preflightEligible || state.miniProof == .activeVerified else {
            state.miniQualifiedSince = nil
            state.phase = .observing
            return (state, [])
        }
        if state.miniQualifiedSince == nil { state.miniQualifiedSince = now }
        guard let since = state.miniQualifiedSince, now.timeIntervalSince(since) >= 30 else {
            state.phase = .qualifying(.mini)
            return (state, [])
        }
        guard state.observedUnderlay != .mini else {
            state.phase = .observing
            return (state, [])
        }
        return beginSwitch(state: state, target: .mini, now: now)
    }

    private static func beginSwitch(
        state original: NetworkPolicyState,
        target: ObservedUnderlay,
        now: Date
    ) -> (state: NetworkPolicyState, effects: [NetworkPolicyEffect]) {
        var state = original
        state.nextTransactionSequence &+= 1
        let transactionID = "route-\(state.generation)-\(state.nextTransactionSequence)-\(target.rawValue)"
        state.phase = .switching(transactionID: transactionID, target: target)
        return (state, [.switchRoute(
            transactionID: transactionID,
            target: target,
            deadline: now.addingTimeInterval(10),
            idempotencyKey: transactionID
        )])
    }

    private static func preferredTarget(_ intent: NetworkPolicyIntent) -> ObservedUnderlay {
        intent == .miniPreferred ? .mini : .wifi
    }

    private static func transactionTarget(transactionID: String) -> ObservedUnderlay? {
        transactionID.hasSuffix("-mini") ? .mini : (transactionID.hasSuffix("-wifi") ? .wifi : nil)
    }
}
