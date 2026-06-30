import Foundation
import Testing
@testable import PalmierPro

@Suite("Codex OAuth Responses client")
struct CodexResponsesClientTests {

    @Test func requestUsesResponsesEndpointAndCodexOAuthHeaders() throws {
        let client = CodexResponsesClient(
            model: "gpt-5-codex",
            accessToken: "access-token",
            accountID: "account-123"
        )

        let request = try client.makeRequest(
            system: "You edit video.",
            tools: [],
            messages: [AgentClientMessage(role: .user, content: [["type": "text", "text": "Hello"]])]
        )

        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-123")
        #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")

        let body = try jsonObject(from: try #require(request.httpBody))
        #expect(body["model"] as? String == "gpt-5-codex")
        #expect(body["max_output_tokens"] == nil)
        #expect(body["stream"] as? Bool == true)
    }

    @Test func requestBodyConvertsMessagesAndToolsForResponsesAPI() throws {
        let body = CodexResponsesRequestBody.build(
            model: "gpt-5-codex",
            system: "You edit video.",
            tools: [
                AgentToolSchema(
                    name: "add_clip",
                    description: "Add a clip",
                    inputSchema: [
                        "type": "object",
                        "properties": ["assetId": ["type": "string"]],
                    ]
                ),
            ],
            messages: [
                AgentClientMessage(role: .user, content: [
                    ["type": "text", "text": "Look at this."],
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "abc123"]],
                ]),
                AgentClientMessage(role: .assistant, content: [
                    ["type": "text", "text": "Adding it."],
                    ["type": "tool_use", "id": "call_1", "name": "add_clip", "input": ["assetId": "a1"]],
                ]),
                AgentClientMessage(role: .user, content: [
                    [
                        "type": "tool_result",
                        "tool_use_id": "call_1",
                        "content": [["type": "text", "text": "ok"]],
                        "is_error": false,
                    ],
                ]),
            ]
        )

        #expect(body["model"] as? String == "gpt-5-codex")
        #expect(body["instructions"] as? String == "You edit video.")
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["parallel_tool_calls"] as? Bool == true)
        #expect(body["store"] as? Bool == false)

        let tools = try #require(body["tools"] as? [[String: Any]])
        let firstTool = try #require(tools.first)
        #expect(firstTool["type"] as? String == "function")
        #expect(firstTool["name"] as? String == "add_clip")
        #expect(firstTool["description"] as? String == "Add a clip")
        #expect(firstTool["strict"] as? Bool == false)

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 4)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "user")
        let userContent = try #require(input[0]["content"] as? [[String: Any]])
        #expect(userContent[0]["type"] as? String == "input_text")
        #expect(userContent[1]["type"] as? String == "input_image")
        #expect(userContent[1]["image_url"] as? String == "data:image/png;base64,abc123")

        #expect(input[1]["type"] as? String == "message")
        #expect(input[1]["role"] as? String == "assistant")
        let assistantContent = try #require(input[1]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "output_text")
        #expect(assistantContent[0]["text"] as? String == "Adding it.")

        #expect(input[2]["type"] as? String == "function_call")
        #expect(input[2]["call_id"] as? String == "call_1")
        #expect(input[2]["name"] as? String == "add_clip")
        #expect(input[2]["arguments"] as? String == #"{"assetId":"a1"}"#)

        #expect(input[3]["type"] as? String == "function_call_output")
        #expect(input[3]["call_id"] as? String == "call_1")
        #expect(input[3]["output"] as? String == "ok")
    }

    @Test func sseConvertsTextAndCompletedEvents() throws {
        var pendingTools: [String: CodexResponsesSSE.PendingToolCall] = [:]

        let textEvents = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.output_text.delta","delta":"Hi"}"#,
            pendingTools: &pendingTools
        )
        #expect(textEvents.count == 1)
        if case .textDelta(let text) = try #require(textEvents.first) {
            #expect(text == "Hi")
        } else {
            Issue.record("Expected text delta")
        }

        let completedEvents = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.completed","response":{"id":"resp_1"}}"#,
            pendingTools: &pendingTools
        )
        if case .messageStop(let stopReason) = try #require(completedEvents.first) {
            #expect(stopReason == .endTurn)
        } else {
            Issue.record("Expected completed stop")
        }
    }

    @Test func sseDoesNotRepeatCompletedMessageItemText() throws {
        var pendingTools: [String: CodexResponsesSSE.PendingToolCall] = [:]

        let events = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","id":"msg_1","content":[{"type":"output_text","text":"Hi"}]}}"#,
            pendingTools: &pendingTools
        )

        #expect(events.isEmpty)
    }

    @Test func sseConvertsFunctionCallDone() throws {
        var pendingTools: [String: CodexResponsesSSE.PendingToolCall] = [:]

        let events = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add_clip","arguments":"{\"assetId\":\"a1\"}"}}"#,
            pendingTools: &pendingTools
        )

        #expect(events.count == 2)
        if case let .toolUseComplete(id, name, inputJSON) = try #require(events.first) {
            #expect(id == "call_1")
            #expect(name == "add_clip")
            #expect(inputJSON == #"{"assetId":"a1"}"#)
        } else {
            Issue.record("Expected tool use")
        }
        if case .messageStop(let stopReason) = try #require(events.last) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected tool stop")
        }
    }

    @Test func sseCompletedAfterFunctionCallKeepsToolUseStop() throws {
        var pendingTools: [String: CodexResponsesSSE.PendingToolCall] = [:]

        _ = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_timeline","arguments":"{}"}}"#,
            pendingTools: &pendingTools
        )
        let completedEvents = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.completed","response":{"id":"resp_1","output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_timeline","arguments":"{}"}]}}"#,
            pendingTools: &pendingTools
        )

        #expect(completedEvents.count == 1)
        if case .messageStop(let stopReason) = try #require(completedEvents.first) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected tool-use stop")
        }
    }

    @Test func sseFlushesFunctionCallArgumentsDeltas() throws {
        var pendingTools: [String: CodexResponsesSSE.PendingToolCall] = [:]

        _ = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"add_clip","arguments":""}}"#,
            pendingTools: &pendingTools
        )
        _ = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"assetId\":\""}"#,
            pendingTools: &pendingTools
        )
        let events = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"a1\"}"}"#,
            pendingTools: &pendingTools
        )
        #expect(events.isEmpty)

        let doneEvents = try CodexResponsesSSE.events(
            fromLine: #"data: {"type":"response.completed","response":{"id":"resp_1"}}"#,
            pendingTools: &pendingTools
        )
        #expect(doneEvents.count == 2)
        if case let .toolUseComplete(id, name, inputJSON) = try #require(doneEvents.first) {
            #expect(id == "call_1")
            #expect(name == "add_clip")
            #expect(inputJSON == #"{"assetId":"a1"}"#)
        } else {
            Issue.record("Expected pending tool use")
        }
        if case .messageStop(let stopReason) = try #require(doneEvents.last) {
            #expect(stopReason == .toolUse)
        } else {
            Issue.record("Expected pending tool stop")
        }
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
