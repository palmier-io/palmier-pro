import Foundation
import Testing
@testable import PalmierPro

@Suite("OpenAI-compatible client")
struct OpenAICompatibleClientTests {

    @Test func normalizesChatCompletionsEndpoint() {
        #expect(OpenAICompatibleEndpoint.normalizedURL(from: "https://example.com")?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(OpenAICompatibleEndpoint.normalizedURL(from: "https://example.com/api/v1")?.absoluteString == "https://example.com/api/v1/chat/completions")
        #expect(OpenAICompatibleEndpoint.normalizedURL(from: "https://example.com/v1/chat/completions")?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(OpenAICompatibleEndpoint.normalizedURL(from: "not a url") == nil)
    }

    @Test func requestBodyConvertsMessagesAndTools() throws {
        let tools = [
            AgentToolSchema(
                name: "add_clip",
                description: "Add a clip",
                inputSchema: [
                    "type": "object",
                    "properties": ["assetId": ["type": "string"]],
                ]
            ),
        ]
        let messages = [
            AgentClientMessage(role: .user, content: [
                ["type": "text", "text": "Look at this."],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "abc123"]],
            ]),
            AgentClientMessage(role: .assistant, content: [
                ["type": "text", "text": "Adding it."],
                ["type": "tool_use", "id": "toolu_1", "name": "add_clip", "input": ["assetId": "a1"]],
            ]),
            AgentClientMessage(role: .user, content: [
                [
                    "type": "tool_result",
                    "tool_use_id": "toolu_1",
                    "content": [["type": "text", "text": "ok"]],
                    "is_error": false,
                ],
            ]),
        ]

        let body = OpenAICompatibleRequestBody.build(
            model: "local-model",
            maxTokens: 123,
            system: "You edit video.",
            tools: tools,
            messages: messages
        )

        #expect(body["model"] as? String == "local-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 123)

        let openAITools = try #require(body["tools"] as? [[String: Any]])
        let firstTool = try #require(openAITools.first)
        #expect(firstTool["type"] as? String == "function")
        let function = try #require(firstTool["function"] as? [String: Any])
        #expect(function["name"] as? String == "add_clip")

        let openAIMessages = try #require(body["messages"] as? [[String: Any]])
        #expect(openAIMessages.count == 4)
        #expect(openAIMessages[0]["role"] as? String == "system")

        let userContent = try #require(openAIMessages[1]["content"] as? [[String: Any]])
        #expect(userContent[0]["type"] as? String == "text")
        #expect(userContent[1]["type"] as? String == "image_url")
        let imageURL = try #require(userContent[1]["image_url"] as? [String: Any])
        #expect(imageURL["url"] as? String == "data:image/png;base64,abc123")

        #expect(openAIMessages[2]["role"] as? String == "assistant")
        let toolCalls = try #require(openAIMessages[2]["tool_calls"] as? [[String: Any]])
        let toolCall = try #require(toolCalls.first)
        #expect(toolCall["id"] as? String == "toolu_1")
        let toolFunction = try #require(toolCall["function"] as? [String: Any])
        #expect(toolFunction["name"] as? String == "add_clip")
        #expect(toolFunction["arguments"] as? String == #"{"assetId":"a1"}"#)

        #expect(openAIMessages[3]["role"] as? String == "tool")
        #expect(openAIMessages[3]["tool_call_id"] as? String == "toolu_1")
        #expect(openAIMessages[3]["content"] as? String == "ok")
    }

    @Test func sseConvertsTextAndToolDeltas() throws {
        var pendingTools: [Int: OpenAICompatibleSSE.PendingToolCall] = [:]

        let textEvents = try OpenAICompatibleSSE.events(
            fromDataLine: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#,
            pendingTools: &pendingTools
        )
        #expect(textEvents.count == 1)
        if case .textDelta(let text) = try #require(textEvents.first) {
            #expect(text == "Hi")
        } else {
            Issue.record("Expected text delta")
        }

        _ = try OpenAICompatibleSSE.events(
            fromDataLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"add_clip","arguments":"{\"assetId\":\""}}]}}]}"#,
            pendingTools: &pendingTools
        )
        _ = try OpenAICompatibleSSE.events(
            fromDataLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"a1\"}"}}]}}]}"#,
            pendingTools: &pendingTools
        )
        let toolEvents = try OpenAICompatibleSSE.events(
            fromDataLine: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            pendingTools: &pendingTools
        )

        #expect(toolEvents.count == 2)
        if case let .toolUseComplete(id, name, inputJSON) = try #require(toolEvents.first) {
            #expect(id == "call_1")
            #expect(name == "add_clip")
            #expect(inputJSON == #"{"assetId":"a1"}"#)
        } else {
            Issue.record("Expected tool use")
        }

        if case .messageStop(let stopReason) = try #require(toolEvents.last) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected tool stop")
        }
    }

    @Test func sseFlushesToolCallsWhenProviderFinishesWithStop() throws {
        var pendingTools: [Int: OpenAICompatibleSSE.PendingToolCall] = [:]

        _ = try OpenAICompatibleSSE.events(
            fromDataLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_transcript","arguments":"{\"wordTimestamps\":true}"}}]}}]}"#,
            pendingTools: &pendingTools
        )
        let events = try OpenAICompatibleSSE.events(
            fromDataLine: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            pendingTools: &pendingTools
        )

        #expect(events.count == 2)
        if case let .toolUseComplete(id, name, inputJSON) = try #require(events.first) {
            #expect(id == "call_1")
            #expect(name == "get_transcript")
            #expect(inputJSON == #"{"wordTimestamps":true}"#)
        } else {
            Issue.record("Expected pending tool use to flush")
        }

        if case .messageStop(let stopReason) = try #require(events.last) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected tool stop")
        }
        #expect(pendingTools.isEmpty)
    }

    @Test func sseFlushesToolCallsOnDoneAndEOF() throws {
        var donePending: [Int: OpenAICompatibleSSE.PendingToolCall] = [:]
        _ = try OpenAICompatibleSSE.events(
            fromDataLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_timeline","arguments":"{}"}}]}}]}"#,
            pendingTools: &donePending
        )
        let doneEvents = try OpenAICompatibleSSE.events(fromDataLine: "data: [DONE]", pendingTools: &donePending)
        if case .messageStop(let stopReason) = try #require(doneEvents.last) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected done to stop for tool use")
        }
        #expect(donePending.isEmpty)

        var eofPending: [Int: OpenAICompatibleSSE.PendingToolCall] = [
            0: .init(id: "call_2", name: "remove_tracks", arguments: #"{"trackKinds":["text"]}"#),
        ]
        let eofEvents = OpenAICompatibleSSE.finishStream(pendingTools: &eofPending)
        if case let .toolUseComplete(id, name, inputJSON) = try #require(eofEvents.first) {
            #expect(id == "call_2")
            #expect(name == "remove_tracks")
            #expect(inputJSON == #"{"trackKinds":["text"]}"#)
        } else {
            Issue.record("Expected EOF to flush pending tool")
        }
        if case .messageStop(let stopReason) = try #require(eofEvents.last) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected EOF tool stop")
        }
        #expect(eofPending.isEmpty)
    }
}
