import Foundation
import Testing
@testable import CompositorPro

@Suite("Text-only agent delegation")
struct AgentDelegationTests {
    @Test(arguments: [
        (403, "permission_denied", "Forbidden", AgentDelegationError.permissionDenied),
        (451, "unavailable", "Restricted", .permissionDenied),
        (400, "permission_denied", "Forbidden", .permissionDenied),
        (400, "content_policy_violation", "Request denied", .modelRefusal),
        (401, "authentication_error", "Sign in", .authenticationRequired),
        (402, "insufficient_credits", "Top up", .insufficientCredits),
    ])
    func hostedStructuredDenialsCannotBecomeOperationalFallback(status: Int, code: String, message: String,
                                                               expected: AgentDelegationError) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
        let error = AgentServiceError.from(status: status, body: String(decoding: data, as: UTF8.self))
        let delegation = AgentDelegation(worker: { _, _, _ in throw error })
        let receipt = try await Self.run(delegation, tasks: Self.tasks(1))
        #expect(receipt.tasks.first?.status == .refused)
        #expect(receipt.tasks.first?.reason == expected.rawValue)
        #expect(!receipt.fallbackRequired)
        #expect(await delegation.permitsFallback == false)
    }

    @Test func defaultWorkersOverlapWithoutExceedingTwoAndResultsKeepInputOrder() async throws {
        let probe = DelegationWorkerProbe()
        let gates = [DelegationGate(), DelegationGate(), DelegationGate(), DelegationGate()]
        let tasks = Self.tasks(4)
        let delegation = AgentDelegation(worker: { task, _, _ in
            let index = try #require(Int(task.id))
            return try await probe.perform(task.id, gate: gates[index])
        })
        let run = Task { try await Self.run(delegation, tasks: tasks) }

        await probe.waitForCalls(2)
        #expect(await probe.active == 2)
        await gates[1].open()
        await probe.waitForCalls(3)
        await gates[2].open()
        await probe.waitForCalls(4)
        await gates[3].open()
        await gates[0].open()

        let receipt = try await run.value
        #expect(receipt.tasks.map(\.id) == tasks.map(\.id))
        #expect(receipt.tasks.map(\.result) == tasks.map { "Prepared \($0.id)" })
        #expect(receipt.tasks.allSatisfy { $0.status == .completed && $0.attempts == 1 })
        #expect(!receipt.fallbackRequired)
        #expect(await probe.peakActive == 2)
        #expect(await probe.calls.count == 4)
        #expect(await probe.active == 0)
    }

    /// Measured-parallelism proof: with fixed injected latency, delegation
    /// finishes four independent tasks materially faster than sequential
    /// execution, without exceeding two in-flight workers.
    @Test func parallelPreparationIsFasterThanSequentialExecution() async throws {
        let probe = DelegationWorkerProbe()
        let latency = Duration.milliseconds(150)
        let worker: @Sendable (AgentDelegationTask, String, AgentRequestContext) async throws -> String = { task, _, _ in
            _ = await probe.begin(task.id)
            do {
                try await Task.sleep(for: latency)
                await probe.end()
                return "Prepared \(task.id)"
            } catch {
                await probe.end(cancelled: error is CancellationError)
                throw error
            }
        }
        // Sequential baseline: same worker, one task at a time.
        let tasks2 = Self.tasks(4)
        let seqStart = ContinuousClock.now
        for task in tasks2 {
            _ = try await worker(task, "Prepare", Self.context())
        }
        let seq = ContinuousClock.now - seqStart

        let delegation = AgentDelegation(worker: worker)
        let parStart = ContinuousClock.now
        let receipt = try await Self.run(delegation, tasks: tasks2)
        let par = ContinuousClock.now - parStart

        #expect(receipt.tasks.map(\.id) == tasks2.map(\.id))
        #expect(await probe.peakActive <= 2)
        #expect(par < seq, "delegated \(par) should beat sequential \(seq)")
    }

    @Test func unsupportedModelDisablesLaterBatchesWithoutStartingTheirWorkers() async throws {
        let probe = DelegationWorkerProbe()
        let delegation = AgentDelegation(worker: { task, _, _ in
            _ = await probe.begin(task.id)
            await probe.end()
            throw AgentDelegationError.unsupportedModel
        })

        let failed = try await Self.run(delegation, tasks: Self.tasks(4))
        let skipped = try await Self.run(delegation, tasks: Self.tasks(3))

        #expect(failed.tasks.first?.reason == "unsupported_model")
        #expect(failed.tasks.first?.attempts == 1)
        #expect(failed.tasks.suffix(2).allSatisfy { $0.status == .fallbackRequired && $0.attempts == 0 })
        #expect(skipped.tasks.allSatisfy { $0.status == .fallbackRequired && $0.attempts == 0 && $0.result == nil })
        #expect(skipped.fallbackRequired)
        #expect(await probe.calls.sorted() == ["0", "1"])
        #expect(await delegation.isEnabled == false)
    }

    @Test func transientFailuresRetryTwiceThenMayComplete() async throws {
        let probe = DelegationWorkerProbe()
        let delegation = AgentDelegation(worker: { task, _, _ in
            let attempt = await probe.begin(task.id)
            await probe.end()
            if attempt <= 2 { throw AgentDelegationError.transientFailure }
            return "Prepared"
        })

        let receipt = try await Self.run(delegation, tasks: Self.tasks(1))

        #expect(receipt.tasks.first?.status == .completed)
        #expect(receipt.tasks.first?.attempts == 3)
        #expect(receipt.tasks.first?.result == "Prepared")
        #expect(await delegation.isEnabled)
    }

    @Test func exhaustedRetriesPreserveCompletedTasksAndNeverRetryTheirWork() async throws {
        let probe = DelegationWorkerProbe()
        let delegation = AgentDelegation(worker: { task, _, _ in
            _ = await probe.begin(task.id)
            await probe.end()
            if task.id == "1" { throw AgentDelegationError.transientFailure }
            return "Prepared \(task.id)"
        })

        let receipt = try await Self.run(delegation, tasks: Self.tasks(2))
        let skipped = try await Self.run(delegation, tasks: Self.tasks(1))

        #expect(receipt.tasks[0].status == .completed)
        #expect(receipt.tasks[0].attempts == 1)
        #expect(receipt.tasks[1].status == .fallbackRequired)
        #expect(receipt.tasks[1].attempts == 3)
        #expect(receipt.tasks[1].result == nil)
        #expect(skipped.tasks.first?.reason == "retries_exhausted")
        #expect(skipped.tasks.first?.attempts == 0)
        #expect(await probe.calls.filter { $0 == "0" }.count == 1)
        #expect(await delegation.isEnabled == false)
    }

    @Test func persistentFailureRequiresFallbackWithoutRetry() async throws {
        let delegation = AgentDelegation(worker: { _, _, _ in throw AgentDelegationError.persistentFailure })
        let receipt = try await Self.run(delegation, tasks: Self.tasks(1))
        #expect(receipt.fallbackRequired)
        #expect(receipt.tasks.first?.attempts == 1)
        #expect(receipt.tasks.first?.reason == "persistent_failure")
        #expect(await delegation.isEnabled == false)
    }

    @Test func repeatedDeadlinesCancelAndDrainWorkersAndDisableFutureWork() async throws {
        let probe = DelegationWorkerProbe()
        let clock = DelegationDeadlineProbe()
        let gate = DelegationGate()
        let delegation = AgentDelegation(
            worker: { task, _, _ in try await probe.perform(task.id, gate: gate) },
            deadline: { try await clock.wait() }
        )
        let run = Task { try await Self.run(delegation, tasks: Self.tasks(1)) }

        await probe.waitForCalls(1)
        await clock.waitForAttempts(1)
        await clock.fire(0)
        await probe.waitForCalls(2)
        await clock.waitForAttempts(2)
        await clock.fire(1)
        let receipt = try await run.value
        let skipped = try await Self.run(delegation, tasks: Self.tasks(1))

        #expect(receipt.tasks.first?.status == .fallbackRequired)
        #expect(receipt.tasks.first?.attempts == 2)
        #expect(skipped.tasks.first?.reason == "repeated_timeout")
        #expect(await probe.calls.count == 2)
        #expect(await probe.cancelled == 2)
        #expect(await probe.active == 0)
        #expect(await clock.active == 0)
    }

    @Test(arguments: [
        AgentDelegationError.authenticationRequired, .insufficientCredits,
        .permissionDenied, .modelRefusal, .toolsForbidden,
    ])
    func denialsBlockEntireRunWithoutRetryOrParentFallback(_ failure: AgentDelegationError) async throws {
        let delegation = AgentDelegation(worker: { _, _, _ in throw failure })
        let receipt = try await Self.run(delegation, tasks: Self.tasks(4))
        let skipped = try await Self.run(delegation, tasks: Self.tasks(1))

        #expect(!receipt.fallbackRequired)
        #expect(receipt.tasks.allSatisfy { $0.status == .refused && $0.result == nil && $0.attempts <= 1 })
        #expect(receipt.tasks.allSatisfy { $0.reason == failure.rawValue })
        #expect(skipped.tasks.first?.status == .refused)
        #expect(skipped.tasks.first?.attempts == 0)
        #expect(await delegation.isEnabled == false)
    }

    @Test func denialSuppressesOperationalFallbackFromAnotherWorker() async throws {
        let delegation = AgentDelegation(worker: { task, _, _ in
            if task.id == "0" { throw AgentDelegationError.unsupportedModel }
            throw AgentDelegationError.authenticationRequired
        })
        let receipt = try await Self.run(delegation, tasks: Self.tasks(4))
        #expect(!receipt.fallbackRequired)
        #expect(receipt.tasks.allSatisfy { $0.status == .refused && $0.result == nil })
    }

    @Test(arguments: [
        (404, "unknown", AgentDelegationError.unsupportedModel),
        (400, "model_not_found", .unsupportedModel),
        (401, "unknown", .authenticationRequired),
        (402, "unknown", .insufficientCredits),
        (403, "unknown", .permissionDenied),
        (429, "insufficient_quota", .insufficientCredits),
        (404, "permission_denied", .permissionDenied),
        (404, "Model does not exist or you do not have access to it", .permissionDenied),
        (400, "Model qwen is not supported", .unsupportedModel),
        (400, "content_policy_violation", .modelRefusal),
    ])
    func transportErrorsDistinguishUnsupportedModelsFromTerminalDenials(
        status: Int, body: String, expected: AgentDelegationError
    ) async throws {
        let client = DelegationRecordingClient(
            failure: AgentClientTransportError.httpError(provider: .custom, status: status, body: body)
        )
        let receipt = try await Self.run(AgentDelegation(), tasks: Self.tasks(1), client: client)

        #expect(receipt.tasks.first?.reason == expected.rawValue)
        #expect(receipt.tasks.first?.result == nil)
        #expect(receipt.fallbackRequired == (expected == .unsupportedModel))
        #expect(receipt.tasks.first?.attempts == 1)
    }

    @Test func toolEventsAreRejectedAndTheirTransportIsCancelled() async throws {
        let probe = DelegationClientProbe()
        let client = DelegationRecordingClient(
            events: [.textDelta("Not a result"), .toolUseComplete(id: "call", name: "spawn_subagents", inputJSON: "{}")],
            probe: probe, transportGate: DelegationGate()
        )
        let receipt = try await Self.run(AgentDelegation(), tasks: Self.tasks(1), client: client)
        try await probe.finished.wait()

        #expect(receipt.tasks.first?.status == .refused)
        #expect(receipt.tasks.first?.reason == "tools_forbidden")
        #expect(receipt.tasks.first?.result == nil)
        #expect(!receipt.fallbackRequired)
        #expect(await probe.cancelled == 1)
        #expect(await probe.requests.first?.toolNames.isEmpty == true)
    }

    @Test(arguments: [
        AgentStopReason.maxTokens, .pauseTurn, .other, .refusal, .toolUse,
    ])
    func nonfinalStopsNeverProduceSuccessfulText(_ stop: AgentStopReason) async throws {
        let client = DelegationRecordingClient(events: [.textDelta("Partial"), .messageStop(stopReason: stop)])
        let receipt = try await Self.run(AgentDelegation(), tasks: Self.tasks(1), client: client)
        #expect(receipt.tasks.first?.status != .completed)
        #expect(receipt.tasks.first?.result == nil)
        if stop == .refusal || stop == .toolUse { #expect(!receipt.fallbackRequired) }
    }

    @Test func missingStopDoesNotPassOffPartialTextAsComplete() async throws {
        let client = DelegationRecordingClient(events: [.textDelta("Partial")])
        let receipt = try await Self.run(AgentDelegation(), tasks: Self.tasks(1), client: client)
        #expect(receipt.tasks.first?.reason == "incomplete_output")
        #expect(receipt.tasks.first?.result == nil)
    }

    @Test(arguments: ["", String(repeating: "é", count: 16_001), "DELEGATION_REFUSED"])
    func invalidTextIsNotReturnedAsSuccessfulWork(_ text: String) async throws {
        let client = DelegationRecordingClient(events: [.textDelta(text), .messageStop(stopReason: .endTurn)])
        let receipt = try await Self.run(AgentDelegation(), tasks: Self.tasks(1), client: client)
        #expect(receipt.tasks.first?.status != .completed)
        #expect(receipt.tasks.first?.result == nil)
        if text == "DELEGATION_REFUSED" { #expect(!receipt.fallbackRequired) }
    }

    @Test func outputByteBoundaryIsAcceptedAndHiddenReasoningIsNotReturned() async throws {
        let text = String(repeating: "é", count: 16_000)
        let client = DelegationRecordingClient(events: [
            .thinkingDelta("private"), .thinkingSignature("signature"), .redactedThinking("redacted"),
            .reasoningSummaryDelta("summary"),
            .reasoningComplete(itemID: "reasoning", summary: "summary", encryptedContent: "encrypted"),
            .textDelta(text), .messageStop(stopReason: .stopSequence),
        ])
        let receipt = try await Self.run(AgentDelegation(), tasks: Self.tasks(1), client: client)
        #expect(receipt.tasks.first?.status == .completed)
        #expect(receipt.tasks.first?.result == text)
    }

    @Test func childRequestsContainOnlyTaskTextAndPrivateIdentityWithParentTrace() async throws {
        let probe = DelegationClientProbe()
        let client = DelegationRecordingClient(
            events: [.textDelta("Prepared"), .messageStop(stopReason: .endTurn)], probe: probe
        )
        let parent = Self.context()
        let tasks = Self.tasks(2)
        let receipt = try await AgentDelegation().run(tasks: tasks, client: client, system: "Prepare", requestContext: parent)
        let requests = await probe.requests

        #expect(receipt.tasks.allSatisfy { $0.status == .completed })
        #expect(requests.count == 2)
        #expect(Set(requests.map { $0.context.conversationID }).count == 2)
        #expect(Set(requests.map { $0.context.spanID }).count == 2)
        #expect(Set(requests.map { $0.context.inputMessageID }).count == 2)
        #expect(Set(requests.map { $0.context.outputMessageID }).count == 2)
        for request in requests {
            #expect(request.toolNames.isEmpty)
            #expect(request.context.traceID == parent.traceID)
            #expect(request.context.projectID == parent.projectID)
            #expect(request.context.conversationID != parent.conversationID)
            #expect(request.context.spanID != parent.spanID)
            #expect(request.context.inputMessageID != parent.inputMessageID)
            #expect(request.context.outputMessageID != parent.outputMessageID)
            #expect(request.messages.count == 1)
            let message = try #require(request.messages.first)
            #expect(message.role == .user)
            #expect(message.content.count == 1)
            guard case .some(.content(.text(let text))) = message.content.first else {
                Issue.record("Worker request was not text-only")
                continue
            }
            #expect(text.contains("Objective:\nPrepare"))
            #expect(text.contains("Immutable context:\nSnapshot"))
        }
        let encoded = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(AgentDelegationReceipt.self, from: encoded) == receipt)
    }

    @Test func cancellationDrainsActiveWorkersAndDeadlinesAndDoesNotAdmitQueuedTasks() async throws {
        let probe = DelegationWorkerProbe()
        let clock = DelegationDeadlineProbe()
        let gate = DelegationGate()
        let delegation = AgentDelegation(
            worker: { task, _, _ in try await probe.perform(task.id, gate: gate) },
            deadline: { try await clock.wait() }
        )
        let run = Task { try await Self.run(delegation, tasks: Self.tasks(4)) }
        await probe.waitForCalls(2)
        await clock.waitForAttempts(2)
        run.cancel()

        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(await probe.calls.count == 2)
        #expect(await probe.cancelled == 2)
        #expect(await probe.active == 0)
        #expect(await clock.active == 0)
    }

    @Test func cancellationTerminatesClientTransport() async throws {
        let probe = DelegationClientProbe()
        let client = DelegationRecordingClient(probe: probe, transportGate: DelegationGate())
        let run = Task { try await Self.run(AgentDelegation(), tasks: Self.tasks(1), client: client) }
        try await probe.started.wait()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        try await probe.finished.wait()
        #expect(await probe.cancelled == 1)
    }

    @Test func overlappingRunsAreRefusedInsteadOfMultiplyingConcurrency() async throws {
        let probe = DelegationWorkerProbe()
        let gate = DelegationGate()
        let delegation = AgentDelegation(worker: { task, _, _ in try await probe.perform(task.id, gate: gate) })
        let run = Task { try await Self.run(delegation, tasks: Self.tasks(1)) }
        await probe.waitForCalls(1)
        await #expect(throws: AgentDelegationError.runInProgress) {
            try await Self.run(delegation, tasks: Self.tasks(1))
        }
        await gate.open()
        _ = try await run.value
    }

    @Test(arguments: InvalidInput.allCases)
    func validationRejectsWholeBatchBeforeAnyWorkStarts(_ input: InvalidInput) async throws {
        let probe = DelegationWorkerProbe()
        let delegation = AgentDelegation(worker: { task, _, _ in
            _ = await probe.begin(task.id)
            await probe.end()
            return "Unexpected"
        })
        await #expect(throws: input.error) {
            try await delegation.run(tasks: input.tasks, client: DelegationRecordingClient(), system: input.system, requestContext: Self.context())
        }
        #expect(await probe.calls.isEmpty)
        #expect(await delegation.isEnabled)
    }

    enum InvalidInput: CaseIterable, Equatable, Sendable {
        case emptyBatch, tooManyTasks, duplicateID, emptyID, whitespaceID, controlID, longID
        case emptyObjective, oversizedContext, oversizedSystem

        var tasks: [AgentDelegationTask] {
            switch self {
            case .emptyBatch: []
            case .tooManyTasks: AgentDelegationTests.tasks(9)
            case .duplicateID: Array(repeating: .init(id: "same", objective: "Prepare", context: ""), count: 2)
            case .emptyID: [.init(id: "", objective: "Prepare", context: "")]
            case .whitespaceID: [.init(id: " padded ", objective: "Prepare", context: "")]
            case .controlID: [.init(id: "line\nbreak", objective: "Prepare", context: "")]
            case .longID: [.init(id: String(repeating: "i", count: 129), objective: "Prepare", context: "")]
            case .emptyObjective: [.init(id: "task", objective: " \n", context: "")]
            case .oversizedContext: [.init(id: "task", objective: "Prepare", context: String(repeating: "x", count: 32_000))]
            case .oversizedSystem: AgentDelegationTests.tasks(1)
            }
        }

        var system: String { self == .oversizedSystem ? String(repeating: "x", count: 64_000) : "Prepare" }

        var error: AgentDelegationError {
            switch self {
            case .emptyBatch, .tooManyTasks: .invalidTaskCount
            case .duplicateID: .duplicateTaskID
            case .emptyID, .whitespaceID, .controlID, .longID: .invalidTaskID
            case .emptyObjective: .emptyObjective
            case .oversizedContext, .oversizedSystem: .inputLimitExceeded
            }
        }
    }

    private static func tasks(_ count: Int) -> [AgentDelegationTask] {
        (0..<count).map { .init(id: String($0), objective: "Prepare \($0)", context: "Snapshot \($0)") }
    }

    private static func context() -> AgentRequestContext {
        .init(conversationID: UUID(), traceID: UUID(), spanID: UUID(), inputMessageID: UUID(), outputMessageID: UUID(), projectID: "isolated-project")
    }

    private static func run(
        _ delegation: AgentDelegation,
        tasks: [AgentDelegationTask],
        client: any AgentClient = DelegationRecordingClient()
    ) async throws -> AgentDelegationReceipt {
        try await delegation.run(tasks: tasks, client: client, system: "Prepare", requestContext: context())
    }
}

private actor DelegationGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if isOpen { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func open() {
        isOpen = true
        let waiting = waiters.values
        waiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor DelegationWorkerProbe {
    private(set) var calls: [String] = []
    private(set) var active = 0
    private(set) var peakActive = 0
    private(set) var cancelled = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func begin(_ id: String) -> Int {
        calls.append(id)
        active += 1
        peakActive = max(active, peakActive)
        let ready = waiters.filter { $0.0 <= calls.count }
        waiters.removeAll { $0.0 <= calls.count }
        for (_, continuation) in ready { continuation.resume() }
        return calls.filter { $0 == id }.count
    }

    func end(cancelled: Bool = false) {
        active -= 1
        if cancelled { self.cancelled += 1 }
    }

    func perform(_ id: String, gate: DelegationGate) async throws -> String {
        _ = begin(id)
        do {
            try await gate.wait()
            try Task.checkCancellation()
            end()
            return "Prepared \(id)"
        } catch {
            end(cancelled: error is CancellationError)
            throw error
        }
    }

    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor DelegationDeadlineProbe {
    private var gates: [DelegationGate] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var active = 0

    func wait() async throws {
        let gate = DelegationGate()
        gates.append(gate)
        active += 1
        defer { active -= 1 }
        let ready = waiters.filter { $0.0 <= gates.count }
        waiters.removeAll { $0.0 <= gates.count }
        for (_, continuation) in ready { continuation.resume() }
        try await gate.wait()
    }

    func waitForAttempts(_ count: Int) async {
        if gates.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func fire(_ index: Int) async { await gates[index].open() }
}

private struct DelegationClientRequest: Sendable {
    let toolNames: [String]
    let messages: [AgentRequestMessage]
    let context: AgentRequestContext
}

private actor DelegationClientProbe {
    let started = DelegationGate()
    let finished = DelegationGate()
    private(set) var requests: [DelegationClientRequest] = []
    private(set) var cancelled = 0

    func record(tools: [AgentToolSchema], messages: [AgentRequestMessage], context: AgentRequestContext) async {
        requests.append(.init(toolNames: tools.map(\.name), messages: messages, context: context))
        await started.open()
    }

    func finish(cancelled: Bool) async {
        if cancelled { self.cancelled += 1 }
        await finished.open()
    }
}

private struct DelegationRecordingClient: AgentClient {
    var events: [AgentStreamEvent] = []
    var failure: (any Error)?
    var probe = DelegationClientProbe()
    var transportGate: DelegationGate?

    func stream(
        system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage], context: AgentRequestContext
    ) -> AgentStreamOperation {
        makeAgentStream { continuation in
            await probe.record(tools: tools, messages: messages, context: context)
            do {
                if let failure { throw failure }
                for event in events {
                    try Task.checkCancellation()
                    continuation.yield(event)
                }
                if let transportGate { try await transportGate.wait() }
                await probe.finish(cancelled: false)
            } catch {
                await probe.finish(cancelled: error is CancellationError)
                throw error
            }
        }
    }
}
