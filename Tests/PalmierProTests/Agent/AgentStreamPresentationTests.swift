import Foundation
import Testing
@testable import PalmierPro

@Suite("Agent stream presentation")
@MainActor
struct AgentStreamPresentationTests {
    @Test func burstCoalescesWithoutChangingText() async throws {
        let chunks = Array(repeating: AgentStreamEvent.textDelta("x"), count: 1_951)
        let recorder = SnapshotRecorder()

        let final = try await presentAgentStream(stream(chunks), model: .sonnet5) {
            await recorder.append($0)
        }

        #expect(text(in: final.blocks) == String(repeating: "x", count: 1_951))
        #expect(await recorder.count <= 2)
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
              case .openAIReasoning(let summary, let encrypted, _, _) = final.blocks[1],
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
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func text(in blocks: [AgentContentBlock]) -> String {
        blocks.compactMap {
            guard case .text(let text) = $0 else { return nil }
            return text
        }.joined()
    }
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
