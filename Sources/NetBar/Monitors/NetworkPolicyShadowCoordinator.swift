import Foundation

struct NetworkPolicyShadowObservation: Equatable {
    let intent: NetworkPolicyIntent
    let observedUnderlay: ObservedUnderlay
    let miniProof: CandidateProof
    let wifiProof: CandidateProof
    let observedAt: Date

    static func make(
        snapshot: NetworkModeSnapshot,
        preference: NetworkRoutePreference,
        currentUnderlayVerified: Bool,
        wifiCandidates: [NetworkAccessCandidate],
        observedAt: Date
    ) -> NetworkPolicyShadowObservation {
        let underlay: ObservedUnderlay
        switch snapshot.effectiveMode {
        case .macMiniGateway:
            underlay = .mini
        case .localWiFi:
            underlay = .wifi
        case nil:
            underlay = snapshot.physicalDefaultInterface == nil ? .none : .ambiguous
        }

        let miniProof: CandidateProof
        switch snapshot.linkState {
        case .disconnected, .unavailable, .addressNotProvisioned, .miniUnreachable:
            miniProof = .unavailable(.linkUnavailable)
        case .connected:
            switch snapshot.gatewayState {
            case .ready:
                miniProof = underlay == .mini && currentUnderlayVerified
                    ? .activeVerified
                    : .preflightEligible
            case .carrierDown, .addressRecovering:
                miniProof = .unavailable(.miniUpstreamUnavailable)
            case .sharingRecovering, .sharingForwardingUnavailable, .configurationDrift,
                 .recoveryBackoff:
                miniProof = .unavailable(.sharingUnavailable)
            case .boundEgressUnavailable:
                miniProof = .unavailable(.downstreamEgressUnavailable)
            case .remoteEvidenceConflict:
                miniProof = .unavailable(.evidenceConflict)
            case .readyStabilizing, .routeFlapping, .remoteStatusUnavailable, .unknown:
                miniProof = .unknown
            }
        }

        let wifiProof: CandidateProof
        if underlay == .wifi && currentUnderlayVerified {
            wifiProof = .activeVerified
        } else if wifiCandidates.contains(where: {
            $0.state == .internetReady || $0.state == .proxyDegraded
        }) {
            wifiProof = .preflightEligible
        } else if snapshot.wifiDevice == nil {
            wifiProof = .unavailable(.wifiUnavailable)
        } else {
            wifiProof = .unknown
        }

        return NetworkPolicyShadowObservation(
            intent: preference == .miniPreferred ? .miniPreferred : .wifiPreferred,
            observedUnderlay: underlay,
            miniProof: miniProof,
            wifiProof: wifiProof,
            observedAt: observedAt
        )
    }
}

/// Read-only rollout driver for `NetworkPolicyMachine`.
///
/// It intentionally has no executor dependency. Effects are proposals written to
/// the diagnostic log; the legacy controller remains the only writer until the
/// 24-hour shadow gate has been reviewed.
actor NetworkPolicyShadowCoordinator {
    struct DiagnosticSnapshot: Equatable {
        let generation: UInt64
        let state: NetworkPolicyState
        let pendingDebounce: Bool
    }

    private let eventLogger: NetworkEventLogging
    private let debounceNanoseconds: UInt64
    private var state = NetworkPolicyState.initial
    private var generation: UInt64 = 0
    private var debounceSequence: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var generationAwaitingObservation = false
    private var lastEvidenceFingerprint: String?
    private var lastObservationFingerprint: String?

    init(
        eventLogger: NetworkEventLogging = NetworkEventLogger.shared,
        debounceNanoseconds: UInt64 = 250_000_000
    ) {
        self.eventLogger = eventLogger
        self.debounceNanoseconds = debounceNanoseconds
    }

    func networkDidChange(_ event: NetworkChangeEvent) {
        debounceSequence &+= 1
        let sequence = debounceSequence
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await finishDebounce(sequence: sequence, event: event)
        }
    }

    func observe(_ observation: NetworkPolicyShadowObservation) {
        let evidenceFingerprint = [
            observation.intent.rawValue,
            observation.observedUnderlay.rawValue,
            proofDescription(observation.miniProof),
            proofDescription(observation.wifiProof)
        ].joined(separator: "|")
        if generation == 0 {
            generation = 1
        } else if lastEvidenceFingerprint != nil,
                  lastEvidenceFingerprint != evidenceFingerprint,
                  !generationAwaitingObservation {
            generation &+= 1
            eventLogger.record(
                event: "network_policy_shadow_generation",
                detail: "generation=\(generation) trigger=evidenceChange",
                candidateSSID: nil
            )
        }
        lastEvidenceFingerprint = evidenceFingerprint
        generationAwaitingObservation = false

        var effects: [NetworkPolicyEffect] = []
        if state.intent != observation.intent {
            let preference = NetworkPolicyMachine.reduce(
                state: state,
                event: .preferenceChanged(observation.intent, at: observation.observedAt)
            )
            state = preference.state
            effects.append(contentsOf: preference.effects)
        }
        let evidence = NetworkPolicyMachine.reduce(
            state: state,
            event: .evidence(
                generation: generation,
                observedUnderlay: observation.observedUnderlay,
                mini: observation.miniProof,
                wifi: observation.wifiProof,
                at: observation.observedAt
            )
        )
        state = evidence.state
        effects.append(contentsOf: evidence.effects)

        let fingerprint = [
            "generation=\(generation)",
            "intent=\(observation.intent.rawValue)",
            "underlay=\(observation.observedUnderlay.rawValue)",
            "mini=\(proofDescription(observation.miniProof))",
            "wifi=\(proofDescription(observation.wifiProof))",
            "phase=\(phaseDescription(state.phase))"
        ].joined(separator: " ")
        if fingerprint != lastObservationFingerprint {
            lastObservationFingerprint = fingerprint
            eventLogger.record(
                event: "network_policy_shadow_observation",
                detail: fingerprint,
                candidateSSID: nil
            )
        }
        for effect in effects {
            eventLogger.record(
                event: "network_policy_shadow_proposal",
                detail: "generation=\(generation) \(effectDescription(effect))",
                candidateSSID: nil
            )
        }
    }

    func diagnosticSnapshot() -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            generation: generation,
            state: state,
            pendingDebounce: debounceTask != nil
        )
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func finishDebounce(
        sequence: UInt64,
        event: NetworkChangeEvent
    ) {
        guard sequence == debounceSequence else { return }
        debounceTask = nil
        generation &+= 1
        generationAwaitingObservation = true
        eventLogger.record(
            event: "network_policy_shadow_generation",
            detail: "generation=\(generation) trigger=\(event.description)",
            candidateSSID: nil
        )
    }

    private func proofDescription(_ proof: CandidateProof) -> String {
        switch proof {
        case .unknown: return "unknown"
        case .unavailable(let reason): return "unavailable:\(reason.rawValue)"
        case .preflightEligible: return "preflightEligible"
        case .activeVerified: return "activeVerified"
        }
    }

    private func phaseDescription(_ phase: NetworkTransitionPhase) -> String {
        switch phase {
        case .observing: return "observing"
        case .qualifying(let target): return "qualifying:\(target.rawValue)"
        case .switching(let transactionID, let target):
            return "switching:\(transactionID):\(target.rawValue)"
        case .rebindingMihomo(let transactionID): return "rebindingMihomo:\(transactionID)"
        case .verifying(let transactionID, let target):
            return "verifying:\(transactionID):\(target.rawValue)"
        case .rollingBack(let transactionID): return "rollingBack:\(transactionID)"
        case .waitingForRecovery: return "waitingForRecovery"
        case .circuitOpen(let until): return "circuitOpen:\(until.timeIntervalSince1970)"
        case .manualRecovery: return "manualRecovery"
        }
    }

    private func effectDescription(_ effect: NetworkPolicyEffect) -> String {
        switch effect {
        case .switchRoute(let transactionID, let target, let deadline, let idempotencyKey):
            return "effect=switchRoute transaction=\(transactionID) target=\(target.rawValue) deadline=\(deadline.timeIntervalSince1970) idempotency=\(idempotencyKey)"
        case .rebindMihomo(let transactionID, let deadline, let idempotencyKey):
            return "effect=rebindMihomo transaction=\(transactionID) deadline=\(deadline.timeIntervalSince1970) idempotency=\(idempotencyKey)"
        case .verify(let transactionID, let target, let deadline):
            return "effect=verify transaction=\(transactionID) target=\(target.rawValue) deadline=\(deadline.timeIntervalSince1970)"
        case .commit(let transactionID): return "effect=commit transaction=\(transactionID)"
        case .rollback(let transactionID, let deadline):
            return "effect=rollback transaction=\(transactionID) deadline=\(deadline.timeIntervalSince1970)"
        case .record(let message): return "effect=record message=\(message)"
        }
    }
}

private extension NetworkChangeEvent {
    var description: String {
        switch self {
        case .physicalLink: return "physicalLink"
        case .addressing: return "addressing"
        case .routing: return "routing"
        case .dns: return "dns"
        case .other: return "other"
        }
    }
}
