import Foundation
import Testing
@testable import CompositorPro

@Suite("Reasoning disclosure and streaming indicator")
struct ReasoningPresentationTests {
    private func block(_ block: AgentContentBlock) -> AgentContentBlock { block }

    @Test("An unfinished thinking block counts as reasoning in progress")
    func incompleteThinkingIsReasoning() {
        #expect(AgentContentBlock.isReasoningComplete(.thinking(text: "working", signature: "")) == false)
        #expect(AgentContentBlock.isReasoningComplete(.thinking(text: "done", signature: "sig")) == true)
    }

    @Test("Redacted reasoning follows whether any data arrived")
    func redactedReasoning() {
        #expect(AgentContentBlock.isReasoningComplete(.redactedThinking(data: "")) == false)
        #expect(AgentContentBlock.isReasoningComplete(.redactedThinking(data: "abc")) == true)
    }

    @Test("OpenAI reasoning uses the stream's own completion flag")
    func openAIReasoning() {
        #expect(
            AgentContentBlock.isReasoningComplete(
                .openAIReasoning(summary: "s", encryptedContent: "e", itemID: nil, model: .sonnet5, isComplete: false)
            ) == false
        )
        #expect(
            AgentContentBlock.isReasoningComplete(
                .openAIReasoning(summary: "s", encryptedContent: "e", itemID: nil, model: .sonnet5, isComplete: true)
            ) == true
        )
    }

    @Test("Text and tool blocks are never reasoning, so they cannot raise the indicator")
    func nonReasoningBlocks() {
        for candidate in [
            AgentContentBlock.text(""),
            .toolUse(id: "t", name: "get_timeline", inputJSON: "{}"),
            .toolResult(toolUseId: "t", content: [], isError: false),
        ] {
            #expect(candidate.isReasoning == false)
            #expect(AgentContentBlock.isReasoningComplete(candidate) == true)
        }
    }

    @Test("A text-only turn does not claim to have reasoned")
    func textOnlyTurnHasNoReasoning() {
        let message = AgentMessage(role: .assistant, blocks: [.text("Here is the answer.")])
        #expect(message.hasIncompleteReasoning == false, "the indicator must stay hidden")
    }

    @Test("An empty turn does not claim to have reasoned")
    func emptyTurnHasNoReasoning() {
        let message = AgentMessage(role: .assistant, blocks: [])
        #expect(message.hasIncompleteReasoning == false)
    }

    @Test("A turn mid-reasoning does raise the indicator")
    func reasoningTurnRaisesIndicator() {
        let message = AgentMessage(role: .assistant, blocks: [
            .thinking(text: "considering", signature: ""),
        ])
        #expect(message.hasIncompleteReasoning == true)
    }

    @Test("The indicator drops once reasoning completes, even while the turn continues")
    func completedReasoningStopsIndicator() {
        let message = AgentMessage(role: .assistant, blocks: [
            .thinking(text: "considered", signature: "sig"),
            .text("Here is the answer."),
        ])
        #expect(message.hasIncompleteReasoning == false, "reasoning is done; only text remains")
    }

    @Test("Completion is decided per block, not per message")
    func oneFinishedBlockAmongUnfinished() {
        let message = AgentMessage(role: .assistant, blocks: [
            .thinking(text: "first", signature: "sig"),
            .thinking(text: "second", signature: ""),
        ])
        #expect(message.hasIncompleteReasoning == true)
    }

    /// Cancellation removes a turn whose blocks never completed. That must not start showing an
    /// indicator for text that survived.
    @Test("Redacted reasoning that never arrived stops the indicator")
    func emptyRedactedDoesNotRaise() {
        let message = AgentMessage(role: .assistant, blocks: [.redactedThinking(data: "")])
        #expect(message.hasIncompleteReasoning == true, "an empty redacted block is still in flight")
    }
}