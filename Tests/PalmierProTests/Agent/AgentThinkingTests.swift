import Foundation
import Testing
@testable import PalmierPro

@Suite("Agent thinking")
@MainActor
struct AgentThinkingTests {
    @Test func redactedThinkingRoundTripsUnchanged() throws {
        let block = AgentContentBlock.redactedThinking(data: "opaque")
        let decoded = try JSONDecoder().decode(
            AgentContentBlock.self,
            from: JSONEncoder().encode(block)
        )
        let body = AnthropicRequestBody.build(
            model: .sonnet5,
            system: "",
            tools: [],
            messages: [AgentRequestMessage(role: .assistant, content: [.content(decoded)])]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let json = try #require(content.first)

        #expect(json["type"] as? String == "redacted_thinking")
        #expect(json["data"] as? String == "opaque")
        guard case .redactedThinking(let data) = decoded else {
            Issue.record("Expected redacted thinking")
            return
        }
        #expect(data == "opaque")
    }

    @Test func cancellationDropsUnsignedThinkingTurn() {
        let service = AgentService()
        let message = AgentMessage(
            role: .assistant,
            blocks: [.thinking(text: "partial", signature: "")]
        )
        service.messages = [message]

        service.dropEmptyAssistantTurn(id: message.id)

        #expect(service.messages.isEmpty)
    }

    @Test func cancellationKeepsCompleteRedactedThinking() {
        let service = AgentService()
        let message = AgentMessage(
            role: .assistant,
            blocks: [.redactedThinking(data: "opaque")]
        )
        service.messages = [message]

        service.dropEmptyAssistantTurn(id: message.id)

        #expect(service.messages.count == 1)
    }
}
