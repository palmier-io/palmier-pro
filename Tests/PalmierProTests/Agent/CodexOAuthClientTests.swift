import Foundation
import Testing
@testable import PalmierPro

@Suite("Codex OAuth client")
struct CodexOAuthClientTests {

    @Test func normalizesResponsesEndpoint() {
        #expect(CodexResponsesEndpoint.normalizedURL(from: "https://chatgpt.com/backend-api/codex")?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(CodexResponsesEndpoint.normalizedURL(from: "https://chatgpt.com/backend-api/codex/responses")?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(CodexResponsesEndpoint.normalizedURL(from: "not a url") == nil)
    }

    @Test func requestBodyConvertsMessagesAndToolsToResponsesShape() throws {
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

        let body = CodexResponsesRequestBody.build(
            model: "gpt-5.5",
            maxTokens: 123,
            system: "You edit video.",
            tools: tools,
            messages: messages
        )

        #expect(body["model"] as? String == "gpt-5.5")
        #expect(body["instructions"] as? String == "You edit video.")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect(body["max_output_tokens"] as? Int == 123)

        let responseTools = try #require(body["tools"] as? [[String: Any]])
        let firstTool = try #require(responseTools.first)
        #expect(firstTool["type"] as? String == "function")
        #expect(firstTool["name"] as? String == "add_clip")

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 4)

        let userMessage = input[0]
        #expect(userMessage["type"] as? String == "message")
        #expect(userMessage["role"] as? String == "user")
        let userContent = try #require(userMessage["content"] as? [[String: Any]])
        #expect(userContent[0]["type"] as? String == "input_text")
        #expect(userContent[1]["type"] as? String == "input_image")

        let assistantMessage = input[1]
        #expect(assistantMessage["role"] as? String == "assistant")
        let assistantContent = try #require(assistantMessage["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "output_text")

        let toolCall = input[2]
        #expect(toolCall["type"] as? String == "function_call")
        #expect(toolCall["call_id"] as? String == "toolu_1")
        #expect(toolCall["name"] as? String == "add_clip")
        #expect(toolCall["arguments"] as? String == #"{"assetId":"a1"}"#)

        let toolOutput = input[3]
        #expect(toolOutput["type"] as? String == "function_call_output")
        #expect(toolOutput["call_id"] as? String == "toolu_1")
        #expect(toolOutput["output"] as? String == "ok")
    }

    @Test func sseConvertsTextAndFunctionCallEvents() throws {
        var state = CodexResponsesSSE.State()

        let textEvents = try CodexResponsesSSE.events(
            fromDataLine: #"data: {"type":"response.output_text.delta","delta":"Hi"}"#,
            state: &state
        )
        #expect(textEvents.count == 1)
        if case .textDelta(let text) = try #require(textEvents.first) {
            #expect(text == "Hi")
        } else {
            Issue.record("Expected text delta")
        }

        _ = try CodexResponsesSSE.events(
            fromDataLine: #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"add_clip"}}"#,
            state: &state
        )
        _ = try CodexResponsesSSE.events(
            fromDataLine: #"data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"assetId\":\""}"#,
            state: &state
        )
        _ = try CodexResponsesSSE.events(
            fromDataLine: #"data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"a1\"}"}"#,
            state: &state
        )
        let toolEvents = try CodexResponsesSSE.events(
            fromDataLine: #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"add_clip"}}"#,
            state: &state
        )

        #expect(toolEvents.count == 1)
        if case let .toolUseComplete(id, name, inputJSON) = try #require(toolEvents.first) {
            #expect(id == "call_1")
            #expect(name == "add_clip")
            #expect(inputJSON == #"{"assetId":"a1"}"#)
        } else {
            Issue.record("Expected tool use")
        }

        let stopEvents = try CodexResponsesSSE.events(
            fromDataLine: #"data: {"type":"response.completed"}"#,
            state: &state
        )
        if case .messageStop(let stopReason) = try #require(stopEvents.last) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected tool stop")
        }
    }

    @Test func jwtPayloadDecodesBase64URLPayload() throws {
        let payload = #"{"exp":4102444800,"chatgpt_account_id":"acct_123"}"#
        let payloadData = Data(payload.utf8)
        let base64URL = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = try #require(CodexOAuthCredentialStore.jwtPayload("header.\(base64URL).sig"))
        #expect(decoded["chatgpt_account_id"] as? String == "acct_123")
        #expect(decoded["exp"] as? Double == 4_102_444_800)
    }
}
