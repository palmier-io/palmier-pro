import Foundation
import Testing
@testable import PalmierPro

@Suite("OpenRouterClient - message translation")
struct OpenRouterClientTests {

    // MARK: - Message translation

    @Test func translateUserTextMessage() {
        let msg = AnthropicMessage(role: .user, content: [
            ["type": "text", "text": "Hello"]
        ])
        let result = OpenRouterClient.translateMessages([msg])
        #expect(result.count == 1)
        #expect(result[0]["role"] as? String == "user")
        #expect(result[0]["content"] as? String == "Hello")
    }

    @Test func translateUserTextWithMultipleBlocksJoinsIntoContentArray() {
        let msg = AnthropicMessage(role: .user, content: [
            ["type": "text", "text": "Part one"],
            ["type": "text", "text": "Part two"],
        ])
        let result = OpenRouterClient.translateMessages([msg])
        #expect(result.count == 1)
        let content = result[0]["content"] as? [[String: Any]]
        #expect(content?.count == 2)
    }

    @Test func translateImageBlockToDataURL() {
        let msg = AnthropicMessage(role: .user, content: [
            ["type": "image", "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": "abc123",
            ]],
        ])
        let result = OpenRouterClient.translateMessages([msg])
        let content = result[0]["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "image_url")
        let imageURL = (content?.first?["image_url"] as? [String: Any])?["url"] as? String
        #expect(imageURL == "data:image/jpeg;base64,abc123")
    }

    @Test func translateAssistantToolUse() {
        let msg = AnthropicMessage(role: .assistant, content: [
            ["type": "text", "text": "Let me check"],
            ["type": "tool_use", "id": "tu_1", "name": "get_weather", "input": ["city": "NYC"]],
        ])
        let result = OpenRouterClient.translateMessages([msg])
        #expect(result.count == 1)
        #expect(result[0]["role"] as? String == "assistant")
        let toolCalls = result[0]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 1)
        #expect(toolCalls?[0]["id"] as? String == "tu_1")
        let fn = toolCalls?[0]["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "get_weather")
        #expect(fn?["arguments"] as? String == #"{"city":"NYC"}"#)
    }

    @Test func translateToolResult() {
        let msg = AnthropicMessage(role: .user, content: [
            ["type": "tool_result", "tool_use_id": "tu_1", "content": [["type": "text", "text": "75°F"]], "is_error": false],
        ])
        let result = OpenRouterClient.translateMessages([msg])
        #expect(result.count == 1)
        #expect(result[0]["role"] as? String == "tool")
        #expect(result[0]["tool_call_id"] as? String == "tu_1")
        #expect(result[0]["content"] as? String == "75°F")
    }

    @Test func translateToolResultErrorPrefixesContent() {
        let msg = AnthropicMessage(role: .user, content: [
            ["type": "tool_result", "tool_use_id": "tu_1", "content": [["type": "text", "text": "not found"]], "is_error": true],
        ])
        let result = OpenRouterClient.translateMessages([msg])
        #expect((result[0]["content"] as? String)?.hasPrefix("Error:") == true)
    }

    @Test func translateEmptyTextBlockBecomesEmptyString() {
        let msg = AnthropicMessage(role: .user, content: [
            ["type": "text", "text": ""],
        ])
        let result = OpenRouterClient.translateMessages([msg])
        #expect(result[0]["content"] as? String == "")
    }

    @Test func translateEmptyContentArrayBecomesEmptyString() {
        let msg = AnthropicMessage(role: .user, content: [])
        let result = OpenRouterClient.translateMessages([msg])
        #expect(result[0]["content"] as? String == "")
    }

    @Test func translateAssistantOnlyToolUseNoText() {
        let msg = AnthropicMessage(role: .assistant, content: [
            ["type": "tool_use", "id": "tu_1", "name": "search", "input": ["q": "test"]],
        ])
        let result = OpenRouterClient.translateMessages([msg])
        #expect(result[0]["role"] as? String == "assistant")
        // content should be nil when there's no text blocks
        #expect(result[0]["content"] as? [String: Any] ?? nil == nil)
        let toolCalls = result[0]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 1)
    }

    // MARK: - Stop reason mapping

    @Test func mapStopStopReason() {
        #expect(OpenAISSE.mapStopReason("stop") == .endTurn)
    }

    @Test func mapLengthStopReason() {
        #expect(OpenAISSE.mapStopReason("length") == .maxTokens)
    }

    @Test func mapToolCallsStopReason() {
        #expect(OpenAISSE.mapStopReason("tool_calls") == .toolUse)
    }

    @Test func mapContentFilterStopReason() {
        #expect(OpenAISSE.mapStopReason("content_filter") == .refusal)
    }

    @Test func mapUnknownStopReason() {
        #expect(OpenAISSE.mapStopReason("something_else") == .other)
    }
}


