import Foundation
import XCTest
@testable import NetBar

final class NetworkPolicyMachineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testOldGenerationCannotChangeNewState() {
        var state = NetworkPolicyState.initial
        state = NetworkPolicyMachine.reduce(
            state: state,
            event: .evidence(
                generation: 9,
                observedUnderlay: .wifi,
                mini: .unavailable(.linkUnavailable),
                wifi: .activeVerified,
                at: start
            )
        ).state

        let result = NetworkPolicyMachine.reduce(
            state: state,
            event: .evidence(
                generation: 8,
                observedUnderlay: .mini,
                mini: .activeVerified,
                wifi: .unknown,
                at: start.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(result.state, state)
        XCTAssertTrue(result.effects.isEmpty)
    }

    func testDefinitiveMiniFailureProducesOneWiFiSwitchEffect() throws {
        let result = NetworkPolicyMachine.reduce(
            state: .initial,
            event: .evidence(
                generation: 1,
                observedUnderlay: .mini,
                mini: .unavailable(.linkUnavailable),
                wifi: .preflightEligible,
                at: start
            )
        )
        XCTAssertEqual(result.effects.count, 1)
        guard case .switchRoute(_, .wifi, _, _) = try XCTUnwrap(result.effects.first) else {
            return XCTFail("expected one Wi-Fi switch")
        }

        let repeated = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .evidence(
                generation: 1,
                observedUnderlay: .mini,
                mini: .unavailable(.linkUnavailable),
                wifi: .preflightEligible,
                at: start.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(repeated.effects.isEmpty)
    }

    func testDefinitiveMiniFailureAcceptsRouteEligibleWiFiAsSaferFallback() throws {
        let result = NetworkPolicyMachine.reduce(
            state: .initial,
            event: .evidence(
                generation: 1,
                observedUnderlay: .mini,
                mini: .unavailable(.linkUnavailable),
                wifi: .routeEligible,
                at: start
            )
        )

        guard case .switchRoute(_, .wifi, _, _) = try XCTUnwrap(result.effects.first) else {
            return XCTFail("route-eligible Wi-Fi must replace a definitively failed Mini")
        }
    }

    func testDegradedWiFiVerificationCommitsWhenMiniSourceIsDefinitivelyUnavailable() throws {
        var result = NetworkPolicyMachine.reduce(
            state: .initial,
            event: .evidence(
                generation: 2,
                observedUnderlay: .mini,
                mini: .unavailable(.linkUnavailable),
                wifi: .routeEligible,
                at: start
            )
        )
        guard case .switchRoute(let transactionID, .wifi, _, _) = try XCTUnwrap(result.effects.first) else {
            return XCTFail("missing Wi-Fi transaction")
        }
        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .routeApplied(generation: 2, transactionID: transactionID, target: .wifi, at: start)
        )
        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .mihomoRebound(generation: 2, transactionID: transactionID, succeeded: true, at: start)
        )
        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .verified(
                generation: 2,
                transactionID: transactionID,
                target: .wifi,
                proof: .degradedActive(.wifiDNSDependsOnMini),
                at: start
            )
        )

        XCTAssertEqual(result.effects, [.commit(transactionID: transactionID)])
        XCTAssertEqual(result.state.observedUnderlay, .wifi)
        XCTAssertEqual(result.state.wifiProof, .degradedActive(.wifiDNSDependsOnMini))
    }

    func testNewGenerationDuringRouteTransactionProposesRollbackInsteadOfDroppingTransaction() throws {
        var result = NetworkPolicyMachine.reduce(
            state: .initial,
            event: .evidence(
                generation: 3,
                observedUnderlay: .mini,
                mini: .unavailable(.sharingUnavailable),
                wifi: .preflightEligible,
                at: start
            )
        )
        guard case .switchRoute(let transactionID, .wifi, _, _) = try XCTUnwrap(result.effects.first) else {
            return XCTFail("missing transaction")
        }

        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .evidence(
                generation: 4,
                observedUnderlay: .ambiguous,
                mini: .unknown,
                wifi: .routeEligible,
                at: start.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(result.state.phase, .rollingBack(transactionID: transactionID))
        XCTAssertEqual(result.effects, [.rollback(
            transactionID: transactionID,
            deadline: start.addingTimeInterval(11)
        )])
    }

    func testSecondFailedAutomaticMiniReturnWithinTenMinutesOpensCircuitAfterRollback() throws {
        var state = NetworkPolicyState.initial
        state.observedUnderlay = .wifi
        state.wifiProof = .activeVerified

        func qualifyAndFail(
            _ input: NetworkPolicyState,
            generation: UInt64,
            qualifiedAt: Date
        ) throws -> NetworkPolicyState {
            var result = NetworkPolicyMachine.reduce(
                state: input,
                event: .evidence(
                    generation: generation,
                    observedUnderlay: .wifi,
                    mini: .preflightEligible,
                    wifi: .activeVerified,
                    at: qualifiedAt
                )
            )
            result = NetworkPolicyMachine.reduce(
                state: result.state,
                event: .evidence(
                    generation: generation,
                    observedUnderlay: .wifi,
                    mini: .preflightEligible,
                    wifi: .activeVerified,
                    at: qualifiedAt.addingTimeInterval(30)
                )
            )
            guard case .switchRoute(let transactionID, .mini, _, _) = try XCTUnwrap(result.effects.first) else {
                throw XCTSkip("missing Mini transaction")
            }
            result = NetworkPolicyMachine.reduce(
                state: result.state,
                event: .routeApplied(generation: generation, transactionID: transactionID, target: .mini, at: qualifiedAt.addingTimeInterval(30))
            )
            result = NetworkPolicyMachine.reduce(
                state: result.state,
                event: .mihomoRebound(generation: generation, transactionID: transactionID, succeeded: true, at: qualifiedAt.addingTimeInterval(30))
            )
            result = NetworkPolicyMachine.reduce(
                state: result.state,
                event: .verified(
                    generation: generation,
                    transactionID: transactionID,
                    target: .mini,
                    proof: .unavailable(.overlayUnavailable),
                    at: qualifiedAt.addingTimeInterval(30)
                )
            )
            result = NetworkPolicyMachine.reduce(
                state: result.state,
                event: .rolledBack(
                    generation: generation,
                    transactionID: transactionID,
                    succeeded: true,
                    at: qualifiedAt.addingTimeInterval(30)
                )
            )
            return result.state
        }

        state = try qualifyAndFail(state, generation: 10, qualifiedAt: start)
        XCTAssertEqual(state.phase, .waitingForRecovery)
        state = try qualifyAndFail(state, generation: 10, qualifiedAt: start.addingTimeInterval(60))

        XCTAssertEqual(state.phase, .circuitOpen(until: start.addingTimeInterval(690)))
    }

    func testUnknownPreferredPathDoesNotBreakHealthyCurrentPath() {
        let result = NetworkPolicyMachine.reduce(
            state: .initial,
            event: .evidence(
                generation: 2,
                observedUnderlay: .wifi,
                mini: .unknown,
                wifi: .activeVerified,
                at: start
            )
        )
        XCTAssertEqual(result.state.observedUnderlay, .wifi)
        XCTAssertTrue(result.effects.isEmpty)
    }

    func testMiniRequiresThirtySecondsBeforeAutomaticReturn() {
        var state = NetworkPolicyState.initial
        state.observedUnderlay = .wifi
        state.wifiProof = .activeVerified
        var result = NetworkPolicyMachine.reduce(
            state: state,
            event: .evidence(
                generation: 3,
                observedUnderlay: .wifi,
                mini: .preflightEligible,
                wifi: .activeVerified,
                at: start
            )
        )
        XCTAssertEqual(result.state.phase, .qualifying(.mini))
        XCTAssertTrue(result.effects.isEmpty)

        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .evidence(
                generation: 3,
                observedUnderlay: .wifi,
                mini: .preflightEligible,
                wifi: .activeVerified,
                at: start.addingTimeInterval(30)
            )
        )
        XCTAssertEqual(result.effects.count, 1)
        guard case .switchRoute(_, .mini, _, _) = result.effects[0] else {
            return XCTFail("expected Mini switch")
        }
    }

    func testTraceReplayOfRepeatedFailureHasBoundedSideEffects() {
        var state = NetworkPolicyState.initial
        var effects: [NetworkPolicyEffect] = []
        for index in 0..<488 {
            let result = NetworkPolicyMachine.reduce(
                state: state,
                event: .evidence(
                    generation: 4,
                    observedUnderlay: .mini,
                    mini: .unavailable(.downstreamEgressUnavailable),
                    wifi: .preflightEligible,
                    at: start.addingTimeInterval(Double(index))
                )
            )
            state = result.state
            effects.append(contentsOf: result.effects)
        }
        XCTAssertEqual(effects.filter {
            if case .switchRoute = $0 { return true }
            return false
        }.count, 1)
    }

    func testEveryFailedVerificationEndsInRollbackAndManualRecoveryIfRollbackFails() throws {
        var result = NetworkPolicyMachine.reduce(
            state: .initial,
            event: .evidence(
                generation: 5,
                observedUnderlay: .mini,
                mini: .unavailable(.sharingUnavailable),
                wifi: .preflightEligible,
                at: start
            )
        )
        guard case .switchRoute(let transactionID, .wifi, _, _) = try XCTUnwrap(result.effects.first) else {
            return XCTFail("missing transaction")
        }
        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .routeApplied(generation: 5, transactionID: transactionID, target: .wifi, at: start)
        )
        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .mihomoRebound(generation: 5, transactionID: transactionID, succeeded: true, at: start)
        )
        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .verified(generation: 5, transactionID: transactionID, target: .wifi, proof: .unavailable(.overlayUnavailable), at: start)
        )
        XCTAssertEqual(result.state.phase, .rollingBack(transactionID: transactionID))
        XCTAssertEqual(result.effects, [.rollback(transactionID: transactionID, deadline: start.addingTimeInterval(10))])

        result = NetworkPolicyMachine.reduce(
            state: result.state,
            event: .rolledBack(generation: 5, transactionID: transactionID, succeeded: false, at: start)
        )
        XCTAssertEqual(result.state.phase, .manualRecovery)
    }
}
