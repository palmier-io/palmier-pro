import Foundation
import Testing
@testable import CompositorPro

@Suite("Agent transport lifetime")
struct AgentTransportLifetimeTests {
    @Test(arguments: FailurePoint.allCases)
    func presentationJoinsCleanupAfterEventsFinish(_ failure: FailurePoint) async throws {
        let probe = TransportLifetimeProbe()
        let client = GatedTransportClient(probe: probe, failure: failure.streamError,
                                          failsAfterCleanup: failure == .cleanup)
        let run = Task {
            await Self.capture(probe: probe) {
                try await presentAgentStream(Self.stream(client), model: .sonnet5) {
                    await probe.record($0)
                }
            }
        }
        await probe.cleanupEntered.wait()
        #expect(await probe.runExited == false)
        await probe.cleanupRelease.open()
        let result = await run.value
        if let error = failure.error {
            #expect(throws: error) { try result.get() }
        } else {
            let final = try result.get()
            #expect(final.stopReason == .endTurn)
            #expect(Self.text(final) == "Prepared")
            #expect(await probe.cancelledAtCleanupExit == false)
        }
        #expect(await probe.lastSnapshot.map(Self.text) == "Prepared")
        #expect(await probe.exitedBeforeCleanup == false)
    }

    @Test(arguments: [false, true])
    func presentationCancellationJoinsCleanupAndFlushesText(eventsAlreadyFinished: Bool) async throws {
        let probe = TransportLifetimeProbe()
        let client = GatedTransportClient(probe: probe, finishBeforeCleanup: eventsAlreadyFinished)
        let run = Task {
            await Self.capture(probe: probe) {
                try await presentAgentStream(Self.stream(client), model: .sonnet5) {
                    await probe.record($0)
                }
            }
        }
        await probe.snapshotReceived.wait()
        if eventsAlreadyFinished { await probe.cleanupEntered.wait() }
        run.cancel()
        await probe.cleanupEntered.wait()
        await probe.cleanupCancelled.wait()
        #expect(await probe.runExited == false)
        await probe.cleanupRelease.open()
        await #expect(throws: CancellationError.self) { try await run.value.get() }
        #expect(await probe.lastSnapshot.map(Self.text) == "Prepared")
        #expect(await probe.cancelledAtCleanupExit)
        #expect(await probe.exitedBeforeCleanup == false)
    }

    @Test func presentationPreservesObservedFailureWhenCancelledDuringCleanup() async throws {
        let probe = TransportLifetimeProbe()
        let client = GatedTransportClient(probe: probe, failure: .failed, failsAfterCleanup: true)
        let run = Task {
            await Self.capture(probe: probe) {
                try await presentAgentStream(Self.stream(client), model: .sonnet5) {
                    await probe.record($0)
                }
            }
        }
        await probe.cleanupEntered.wait()
        await probe.cleanupCancelled.wait()
        run.cancel()
        #expect(await probe.runExited == false)
        await probe.cleanupRelease.open()
        await #expect(throws: TransportFixtureError.failed) { try await run.value.get() }
        #expect(await probe.lastSnapshot.map(Self.text) == "Prepared")
        #expect(await probe.exitedBeforeCleanup == false)
    }

    @Test(arguments: FailurePoint.allCases)
    func delegationJoinsCleanupAfterCompletionOrTransportFailure(_ failure: FailurePoint) async throws {
        let probe = TransportLifetimeProbe()
        let client = GatedTransportClient(probe: probe, failure: failure.streamError,
                                          failsAfterCleanup: failure == .cleanup)
        let delegation = Self.delegation()
        let run = Task {
            await Self.capture(probe: probe) { try await Self.run(delegation, client: client) }
        }
        await probe.cleanupEntered.wait()
        #expect(await probe.runExited == false)
        await #expect(throws: AgentDelegationError.runInProgress) {
            try await Self.run(delegation, client: client)
        }
        await probe.cleanupRelease.open()
        let receipt = try await run.value.get()
        #expect(receipt.tasks.first?.status == (failure == .none ? .completed : .fallbackRequired))
        #expect(receipt.tasks.first?.reason == (failure == .none ? nil : "persistent_failure"))
        #expect(receipt.tasks.first?.result == (failure == .none ? "Prepared" : nil))
        #expect(await probe.exitedBeforeCleanup == false)
    }

    @Test(arguments: Rejection.allCases)
    func earlyChildRejectionsCancelAndJoinWithoutReplacingTheirReason(_ rejection: Rejection) async throws {
        let probe = TransportLifetimeProbe()
        let client = GatedTransportClient(probe: probe, events: rejection.events,
                                          finishBeforeCleanup: rejection.finishesEvents, failsAfterCleanup: true)
        let delegation = Self.delegation()
        let run = Task {
            await Self.capture(probe: probe) { try await Self.run(delegation, client: client) }
        }
        await probe.cleanupEntered.wait()
        await probe.cleanupCancelled.wait()
        #expect(await probe.runExited == false)
        await #expect(throws: AgentDelegationError.runInProgress) {
            try await Self.run(delegation, client: client)
        }
        await probe.cleanupRelease.open()
        let receipt = try await run.value.get()
        #expect(receipt.tasks.first?.reason == rejection.reason.rawValue)
        #expect(receipt.tasks.first?.status == (rejection.isDenial ? .refused : .fallbackRequired))
        #expect(receipt.fallbackRequired == !rejection.isDenial)
        #expect(receipt.tasks.first?.attempts == 1)
        #expect(receipt.tasks.first?.result == nil)
        #expect(await probe.cancelledAtCleanupExit)
        #expect(await probe.exitedBeforeCleanup == false)
    }

    @Test func delegationCancellationKeepsRunOwnedUntilProducerCleanupExits() async throws {
        let probe = TransportLifetimeProbe()
        let client = GatedTransportClient(probe: probe, finishBeforeCleanup: false)
        let delegation = Self.delegation()
        let run = Task {
            await Self.capture(probe: probe) { try await Self.run(delegation, client: client) }
        }
        await probe.transportWaiting.wait()
        run.cancel()
        await probe.cleanupEntered.wait()
        await probe.cleanupCancelled.wait()
        #expect(await probe.runExited == false)
        await #expect(throws: AgentDelegationError.runInProgress) {
            try await Self.run(delegation, client: client)
        }
        await probe.cleanupRelease.open()
        await #expect(throws: CancellationError.self) { try await run.value.get() }
        #expect(await probe.cancelledAtCleanupExit)
        #expect(await probe.exitedBeforeCleanup == false)
    }

    enum FailurePoint: CaseIterable, Sendable {
        case none, events, cleanup

        fileprivate var streamError: TransportFixtureError? { self == .events ? .failed : nil }

        fileprivate var error: TransportFixtureError? {
            switch self {
            case .none: nil
            case .events: .failed
            case .cleanup: .cleanupFailed
            }
        }
    }

    enum Rejection: CaseIterable, Sendable {
        case toolEvent, toolStop, refusal, incomplete, oversized, textAfterStop, repeatedStop
        case missingStop, empty, refusalText

        var events: [AgentStreamEvent] {
            switch self {
            case .toolEvent: [.toolUseComplete(id: "tool", name: "forbidden", inputJSON: "{}")]
            case .toolStop: [.messageStop(stopReason: .toolUse)]
            case .refusal: [.messageStop(stopReason: .refusal)]
            case .incomplete: [.messageStop(stopReason: .maxTokens)]
            case .oversized: [.textDelta(String(repeating: "x", count: AgentDelegation.textByteLimit + 1))]
            case .textAfterStop: [.messageStop(stopReason: .endTurn), .textDelta("late")]
            case .repeatedStop: [.messageStop(stopReason: .endTurn), .messageStop(stopReason: .endTurn)]
            case .missingStop: [.textDelta("Partial")]
            case .empty: [.messageStop(stopReason: .endTurn)]
            case .refusalText: [.textDelta("DELEGATION_REFUSED"), .messageStop(stopReason: .endTurn)]
            }
        }

        var reason: AgentDelegationError {
            switch self {
            case .toolEvent, .toolStop: .toolsForbidden
            case .refusal, .refusalText: .modelRefusal
            case .empty: .emptyOutput
            case .oversized: .outputLimitExceeded
            default: .incompleteOutput
            }
        }

        var isDenial: Bool { reason == .toolsForbidden || reason == .modelRefusal }

        var finishesEvents: Bool {
            switch self {
            case .missingStop, .empty, .refusalText: true
            default: false
            }
        }
    }

    private static func delegation() -> AgentDelegation {
        AgentDelegation(deadline: { try await TransportCancellationGate().wait() })
    }

    private static func stream(_ client: GatedTransportClient) -> AgentStreamOperation {
        client.stream(system: "Prepare", tools: [], messages: [], context: context())
    }

    private static func run(_ delegation: AgentDelegation, client: GatedTransportClient) async throws -> AgentDelegationReceipt {
        try await delegation.run(
            tasks: [.init(id: "task", objective: "Prepare", context: "Immutable")],
            client: client, system: "Prepare", requestContext: context()
        )
    }

    private static func context() -> AgentRequestContext {
        .init(conversationID: UUID(), traceID: UUID(), spanID: UUID(),
              inputMessageID: UUID(), outputMessageID: UUID(), projectID: nil)
    }

    private static func text(_ snapshot: AgentStreamSnapshot) -> String {
        snapshot.blocks.compactMap {
            guard case .text(let value) = $0 else { return nil }
            return value
        }.joined()
    }

    private static func capture<Value: Sendable>(
        probe: TransportLifetimeProbe,
        operation: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        let result: Result<Value, any Error>
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        await probe.recordRunExit()
        return result
    }
}

private enum TransportFixtureError: Error {
    case failed, cleanupFailed
}

private struct GatedTransportClient: AgentClient {
    let probe: TransportLifetimeProbe
    var events: [AgentStreamEvent] = [.textDelta("Prepared"), .messageStop(stopReason: .endTurn)]
    var failure: TransportFixtureError?
    var finishBeforeCleanup = true
    var failsAfterCleanup = false

    func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                context: AgentRequestContext) -> AgentStreamOperation {
        makeAgentStream { continuation in
            for event in events { continuation.yield(event) }
            if finishBeforeCleanup {
                continuation.finish(throwing: failure)
            } else {
                do { try await probe.waitForTransportCancellation() }
                catch { continuation.finish(throwing: error) }
            }
            await probe.holdCleanup()
            if failsAfterCleanup { throw TransportFixtureError.cleanupFailed }
        }
    }
}

private actor TransportLifetimeProbe {
    let transportWaiting = TransportLifetimeGate()
    let cleanupEntered = TransportLifetimeGate()
    let cleanupRelease = TransportLifetimeGate()
    let cleanupCancelled = TransportLifetimeGate()
    let snapshotReceived = TransportLifetimeGate()
    private let transportCancellation = TransportCancellationGate()
    private var cleanupComplete = false
    private(set) var cancelledAtCleanupExit = false
    private(set) var runExited = false
    private(set) var exitedBeforeCleanup = false
    private(set) var lastSnapshot: AgentStreamSnapshot?

    func waitForTransportCancellation() async throws {
        await transportWaiting.open()
        try await transportCancellation.wait()
    }

    func holdCleanup() async {
        let cleanupCancelled = self.cleanupCancelled
        await withTaskCancellationHandler {
            await cleanupEntered.open()
            await cleanupRelease.wait()
        } onCancel: {
            Task { await cleanupCancelled.open() }
        }
        cancelledAtCleanupExit = Task.isCancelled
        cleanupComplete = true
    }

    func record(_ snapshot: AgentStreamSnapshot) async {
        lastSnapshot = snapshot
        await snapshotReceived.open()
    }

    func recordRunExit() {
        runExited = true
        exitedBeforeCleanup = !cleanupComplete
    }
}

private actor TransportLifetimeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor TransportCancellationGate {
    private var isCancelled = false
    private var waiter: CheckedContinuation<Void, any Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        isCancelled = true
        let pending = waiter
        waiter = nil
        pending?.resume(throwing: CancellationError())
    }
}
