import Foundation
import Testing
@testable import CompositorPro

@Suite("Agent stream presentation")
@MainActor
struct AgentStreamPresentationTests {
    @Test func providerReasoningIsVisibleBeforeAnyTextArrives() async throws {
        let buffer = AgentStreamPresentationBuffer(model: .terra)
        _ = await buffer.snapshots()
        await buffer.receive(.activity(.reasoning))
        let reasoning = await buffer.snapshot
        #expect(reasoning.activity == .reasoning)
        #expect(reasoning.blocks.isEmpty)
        #expect(reasoning.receivedAt != nil)
        await buffer.receive(.textDelta("Answer"))
        let final = await buffer.complete()
        #expect(final.activity == .generating)
        #expect(text(in: final.blocks) == "Answer")
    }

    @Test func burstPreservesEveryTextDelta() async throws {
        let chunks = Array(repeating: AgentStreamEvent.textDelta("x"), count: 1_951)
        let final = try await presentAgentStream(stream(chunks), model: .sonnet5) { _ in }
        #expect(text(in: final.blocks) == String(repeating: "x", count: 1_951))
    }

    @Test func burstWithinOneActorTurnPublishesAtMostTwoSnapshots() async throws {
        let chunks = Array(repeating: AgentStreamEvent.textDelta("x"), count: 1_951)
        let buffer = AgentStreamPresentationBuffer(model: .sonnet5)
        let snapshots = await buffer.snapshots()
        let recorder = SnapshotRecorder()
        let consumer = Task {
            for try await snapshot in snapshots { await recorder.append(snapshot) }
        }
        let final = await deliverPresentationBurst(chunks, to: buffer)
        try await consumer.value
        #expect(text(in: final.blocks) == String(repeating: "x", count: 1_951))
        #expect(await (1...2).contains(recorder.count))
        #expect(await recorder.last.map { text(in: $0.blocks) } == text(in: final.blocks))
    }

    @Test func reducerPreservesBlockOrderAndStopReason() async throws {
        let final = try await presentAgentStream(stream([
            .thinkingDelta("Plan"),
            .thinkingSignature("signed"),
            .reasoningSummaryDelta("Checking"),
            .reasoningComplete(itemID: "rs_1", summary: "", encryptedContent: "encrypted"),
            .textDelta("Done"),
            .toolUseComplete(id: "tool_1", name: "get_timeline", inputJSON: "{}"),
            .messageStop(stopReason: .toolUse),
        ]), model: .sonnet5) { _ in }

        #expect(final.stopReason == .toolUse)
        #expect(final.blocks.count == 4)
        guard case .thinking(let thinking, let signature) = final.blocks[0],
              case .openAIReasoning(let summary, let encrypted, _, _, _) = final.blocks[1],
              case .text(let text) = final.blocks[2],
              case .toolUse(let id, let name, _) = final.blocks[3] else {
            Issue.record("Unexpected final block order")
            return
        }
        #expect(thinking == "Plan")
        #expect(signature == "signed")
        #expect(summary == "Checking")
        #expect(encrypted == "encrypted")
        #expect(text == "Done")
        #expect(id == "tool_1")
        #expect(name == "get_timeline")
    }

    /// A whole turn can arrive inside one 50ms coalescing window. The terminal event must
    /// still reach the caller, or the agent exits as if the model merely finished talking.
    @Test func shortTurnEndingInToolUseIsNotLostToCoalescing() async throws {
        let final = try await presentAgentStream(stream([
            .textDelta("I'll start by reviewing"),
            .toolUseComplete(id: "call_1", name: "get_timeline", inputJSON: "{}"),
            .messageStop(stopReason: .toolUse),
        ]), model: .custom) { _ in }

        #expect(final.stopReason == .toolUse)
        #expect(text(in: final.blocks) == "I'll start by reviewing")
        #expect(final.blocks.contains { block in
            guard case .toolUse(let id, let name, _) = block else { return false }
            return id == "call_1" && name == "get_timeline"
        })
    }

    @Test func upstreamErrorFlushesPartialText() async {
        let recorder = SnapshotRecorder()
        await #expect(throws: FixtureError.self) {
            try await presentAgentStream(
                stream([.textDelta("partial")], error: FixtureError.failed),
                model: .sonnet5
            ) {
                await recorder.append($0)
            }
        }

        #expect(await recorder.last.map { text(in: $0.blocks) } == "partial")
    }

    @Test func stopCompletesReasoningBeforeAnswerAndToolBlocks() async throws {
        let final = try await presentAgentStream(stream([
            .reasoningSummaryDelta("First decision"),
            .textDelta("Starting the edit"),
            .reasoningSummaryDelta("Second decision"),
            .toolUseComplete(id: "call_1", name: "get_timeline", inputJSON: "{}"),
            .messageStop(stopReason: .toolUse),
        ]), model: .custom) { _ in }

        let reasoning = final.blocks.filter(\.isReasoning)
        #expect(reasoning.count == 2)
        #expect(reasoning.allSatisfy(AgentContentBlock.isReasoningComplete))
        #expect(final.stopReason == .toolUse)
    }

    @Test func stopPublishesReasoningCompletionAfterLastContentSnapshot() async throws {
        let receivedReasoning = AsyncSemaphore(value: 0)
        let recorder = SnapshotRecorder()
        let source = makeAgentStream { continuation in
            continuation.yield(.reasoningSummaryDelta("Decision"))
            try await receivedReasoning.wait()
            continuation.yield(.messageStop(stopReason: .endTurn))
        }

        let final = try await presentAgentStream(source, model: .custom) { snapshot in
            await recorder.append(snapshot)
            if snapshot.blocks.contains(where: { !AgentContentBlock.isReasoningComplete($0) }) {
                await receivedReasoning.signal()
            }
        }

        #expect(final.blocks.allSatisfy(AgentContentBlock.isReasoningComplete))
        #expect(await recorder.last?.blocks.allSatisfy(AgentContentBlock.isReasoningComplete) == true)
        #expect(await recorder.count == 2)
    }

    @Test(arguments: ["Final decision", ""])
    func delayedReasoningCompletionUpdatesItsOriginalBlock(_ completedSummary: String) async throws {
        let final = try await presentAgentStream(stream([
            .reasoningSummaryDelta("Decision"),
            .textDelta("Answer"),
            .toolUseComplete(id: "call_1", name: "get_timeline", inputJSON: "{}"),
            .reasoningComplete(itemID: "rs_1", summary: completedSummary, encryptedContent: "encrypted"),
            .messageStop(stopReason: .toolUse),
        ]), model: .terra) { _ in }

        #expect(final.blocks.count == 3)
        guard case .openAIReasoning(let summary, let encrypted, let itemID, _, let isComplete)? = final.blocks.first else {
            Issue.record("Expected reasoning before answer and tool blocks")
            return
        }
        #expect(summary == (completedSummary.isEmpty ? "Decision" : completedSummary))
        #expect(encrypted == "encrypted")
        #expect(itemID == "rs_1")
        #expect(isComplete)
        #expect(text(in: final.blocks) == "Answer")
    }

    @Test func reasoningCompletionsPreserveSeparateItems() async throws {
        let final = try await presentAgentStream(stream([
            .reasoningSummaryDelta("First"),
            .reasoningComplete(itemID: "rs_1", summary: "", encryptedContent: "first"),
            .textDelta("Answer"),
            .reasoningSummaryDelta("Second"),
            .toolUseComplete(id: "call_1", name: "get_timeline", inputJSON: "{}"),
            .reasoningComplete(itemID: "rs_2", summary: "", encryptedContent: "second"),
            .messageStop(stopReason: .toolUse),
        ]), model: .terra) { _ in }

        let reasoning = final.blocks.filter(\.isReasoning)
        try #require(reasoning.count == 2)
        guard case .openAIReasoning(let first, let firstEncrypted, let firstID, _, true) = reasoning[0],
              case .openAIReasoning(let second, let secondEncrypted, let secondID, _, true) = reasoning[1]
        else {
            Issue.record("Expected two completed reasoning items")
            return
        }
        #expect(first == "First" && firstEncrypted == "first" && firstID == "rs_1")
        #expect(second == "Second" && secondEncrypted == "second" && secondID == "rs_2")
        #expect(final.blocks.count == 4)
    }

    @Test func lateSnapshotUpdatesOriginatingSessionAfterSwitch() throws {
        let suiteName = "AgentStreamPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let assistant = AgentMessage(role: .assistant, blocks: [.text("visible")])
        let original = ChatSession(messages: [assistant])
        let selected = ChatSession()
        let service = AgentService(userDefaults: defaults)
        service.sessions = [original, selected]
        service.currentSessionId = selected.id
        service.messages = selected.messages

        service.applyStreamSnapshot(
            AgentStreamSnapshot(
                blocks: [.text("visible plus buffered")],
                stopReason: .endTurn,
                revision: 2
            ),
            assistantID: assistant.id,
            conversationID: original.id
        )

        let stored = try #require(service.sessions.first { $0.id == original.id })
        #expect(text(in: stored.messages[0].blocks) == "visible plus buffered")
        #expect(service.messages.isEmpty)
    }

    private func stream(
        _ events: [AgentStreamEvent],
        error: (any Error)? = nil
    ) -> AgentStreamOperation {
        makeAgentStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let error { throw error }
        }
    }

    private func text(in blocks: [AgentContentBlock]) -> String {
        blocks.compactMap {
            guard case .text(let text) = $0 else { return nil }
            return text
        }.joined()
    }
}

private func deliverPresentationBurst(
    _ events: [AgentStreamEvent],
    to buffer: isolated AgentStreamPresentationBuffer
) -> AgentStreamSnapshot {
    for event in events { buffer.receive(event) }
    return buffer.complete()
}

private enum FixtureError: Error {
    case failed
}

private actor SnapshotRecorder {
    private var snapshots: [AgentStreamSnapshot] = []

    var count: Int { snapshots.count }
    var last: AgentStreamSnapshot? { snapshots.last }

    func append(_ snapshot: AgentStreamSnapshot) {
        snapshots.append(snapshot)
    }
}
