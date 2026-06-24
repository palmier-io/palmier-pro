import XCTest
@testable import AgentTranslation

final class OpenAITranslationTests: XCTestCase {

    // MARK: - Helpers

    private func dict(_ any: Any?) -> [String: Any] { (any as? [String: Any]) ?? [:] }
    private func array(_ any: Any?) -> [[String: Any]] { (any as? [[String: Any]]) ?? [] }
    private func str(_ d: [String: Any], _ key: String) -> String? { d[key] as? String }

    private func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }
    private func imageBlock(mime: String, data: String) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mime, "data": data]]
    }
    private func toolUseBlock(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }
    private func toolResultBlock(id: String, content: Any, isError: Bool = false) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]
    }

    // MARK: - Tool-result -> tool role message

    func testToolResultTextBecomesToolMessage() {
        let turn = AgentTurn(role: .user, content: [
            toolResultBlock(id: "call_1", content: [textBlock("timeline has 3 clips")]),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])

        // [0] is the system message; [1] is the tool message.
        XCTAssertEqual(messages.count, 2)
        let tool = messages[1]
        XCTAssertEqual(str(tool, "role"), "tool")
        XCTAssertEqual(str(tool, "tool_call_id"), "call_1")
        XCTAssertEqual(str(tool, "content"), "timeline has 3 clips")
    }

    func testToolResultErrorIsPrefixed() {
        let turn = AgentTurn(role: .user, content: [
            toolResultBlock(id: "call_err", content: [textBlock("clip not found")], isError: true),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])
        XCTAssertEqual(str(messages[1], "content"), "ERROR: clip not found")
    }

    func testToolResultStringContentSupported() {
        let turn = AgentTurn(role: .user, content: [
            toolResultBlock(id: "c", content: "plain string result"),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])
        XCTAssertEqual(str(messages[1], "content"), "plain string result")
    }

    // MARK: - Tool-result image bridging (the tricky one)

    func testToolResultImageIsBridgedToFollowingUserMessage() {
        let turn = AgentTurn(role: .user, content: [
            toolResultBlock(id: "call_inspect", content: [
                textBlock("frame at 00:05"),
                imageBlock(mime: "image/png", data: "AAAABBBB"),
            ]),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])

        // system, tool, then a user message carrying the image.
        XCTAssertEqual(messages.count, 3)

        let tool = messages[1]
        XCTAssertEqual(str(tool, "role"), "tool")
        XCTAssertEqual(str(tool, "tool_call_id"), "call_inspect")
        // The text part stays on the tool message; the image is deferred.
        XCTAssertEqual(str(tool, "content"), "frame at 00:05")

        let userImage = messages[2]
        XCTAssertEqual(str(userImage, "role"), "user")
        let parts = array(userImage["content"])
        XCTAssertEqual(str(parts[0], "type"), "text")
        XCTAssertEqual(str(parts[1], "type"), "image_url")
        XCTAssertEqual(str(dict(parts[1]["image_url"]), "url"), "data:image/png;base64,AAAABBBB")
    }

    func testToolResultImageOnlyGetsPlaceholderText() {
        let turn = AgentTurn(role: .user, content: [
            toolResultBlock(id: "c", content: [imageBlock(mime: "image/jpeg", data: "ZZZ")]),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])
        // Tool message must still carry non-empty content even when only an image came back.
        XCTAssertEqual(str(messages[1], "content"), "(image content in the following message)")
        XCTAssertEqual(str(messages[2], "role"), "user")
    }

    // MARK: - Message ordering: assistant(tool_calls) -> tool -> deferred image

    func testFullRoundTripOrderingAssistantToolToImage() {
        let assistant = AgentTurn(role: .assistant, content: [
            toolUseBlock(id: "call_1", name: "inspect_timeline", input: ["startFrame": 0]),
        ])
        let toolResult = AgentTurn(role: .user, content: [
            toolResultBlock(id: "call_1", content: [
                textBlock("rendered"),
                imageBlock(mime: "image/png", data: "IMG"),
            ]),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(
            system: "sys", enablePromptCache: false, turns: [assistant, toolResult]
        )

        // system, assistant(tool_calls), tool, user(image)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(str(messages[0], "role"), "system")

        let asst = messages[1]
        XCTAssertEqual(str(asst, "role"), "assistant")
        let calls = array(asst["tool_calls"])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(str(calls[0], "id"), "call_1")
        XCTAssertEqual(str(dict(calls[0]["function"]), "name"), "inspect_timeline")

        // Tool response must immediately follow the assistant tool_calls.
        XCTAssertEqual(str(messages[2], "role"), "tool")
        XCTAssertEqual(str(messages[2], "tool_call_id"), "call_1")

        // Deferred image rides a user message after the tool response.
        XCTAssertEqual(str(messages[3], "role"), "user")
    }

    // MARK: - Assistant tool_use -> tool_calls (arguments serialized)

    func testAssistantToolUseSerializesArgumentsAsJSONString() {
        let turn = AgentTurn(role: .assistant, content: [
            toolUseBlock(id: "abc", name: "set_clip_properties", input: ["clipId": "x", "opacity": 0.5]),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])
        let call = array(messages[1]["tool_calls"])[0]
        XCTAssertEqual(str(call, "type"), "function")
        let fn = dict(call["function"])
        XCTAssertEqual(str(fn, "name"), "set_clip_properties")

        // arguments must be a STRING containing valid JSON, not a nested object.
        let argsString = str(fn, "arguments")
        XCTAssertNotNil(argsString)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(argsString!.utf8))) as? [String: Any]
        XCTAssertEqual(parsed?["clipId"] as? String, "x")
        XCTAssertEqual(parsed?["opacity"] as? Double, 0.5)
    }

    func testAssistantTextAndToolUseCoexist() {
        let turn = AgentTurn(role: .assistant, content: [
            textBlock("Let me check the timeline."),
            toolUseBlock(id: "t1", name: "get_timeline", input: [:]),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])
        let asst = messages[1]
        XCTAssertEqual(str(asst, "content"), "Let me check the timeline.")
        XCTAssertEqual(array(asst["tool_calls"]).count, 1)
    }

    func testAssistantEmptyToolUseArgsAreEmptyObject() {
        let turn = AgentTurn(role: .assistant, content: [
            toolUseBlock(id: "t1", name: "get_timeline", input: [:]),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])
        let fn = dict(array(messages[1]["tool_calls"])[0]["function"])
        XCTAssertEqual(str(fn, "arguments"), "{}")
    }

    // MARK: - Normal user text + image

    func testUserTextAndImageBecomeContentParts() {
        let turn = AgentTurn(role: .user, content: [
            textBlock("what is in this clip?"),
            imageBlock(mime: "image/png", data: "Q1Q1"),
        ])
        let messages = OpenAIRequestBuilder.openAIMessages(system: "sys", enablePromptCache: false, turns: [turn])
        let user = messages[1]
        XCTAssertEqual(str(user, "role"), "user")
        let parts = array(user["content"])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(str(parts[0], "text"), "what is in this clip?")
        XCTAssertEqual(str(dict(parts[1]["image_url"]), "url"), "data:image/png;base64,Q1Q1")
    }

    // MARK: - System caching + tools shape

    func testSystemMessageCachingToggle() {
        let cached = OpenAIRequestBuilder.openAIMessages(system: "PROMPT", enablePromptCache: true, turns: [])
        let cachedParts = array(cached[0]["content"])
        XCTAssertEqual(str(cachedParts[0], "text"), "PROMPT")
        XCTAssertEqual(dict(cachedParts[0]["cache_control"])["type"] as? String, "ephemeral")

        let plain = OpenAIRequestBuilder.openAIMessages(system: "PROMPT", enablePromptCache: false, turns: [])
        XCTAssertEqual(plain[0]["content"] as? String, "PROMPT")
    }

    func testBodyToolsAndChoiceShape() {
        let tools = [AgentToolSchema(
            name: "get_timeline",
            description: "Return the timeline.",
            parameters: ["type": "object", "properties": [:]]
        )]
        let body = OpenAIRequestBuilder.body(
            model: "google/gemini-2.5-flash-lite",
            maxTokens: 8192,
            temperature: nil,
            enablePromptCache: true,
            system: "sys",
            tools: tools,
            turns: []
        )
        XCTAssertEqual(body["model"] as? String, "google/gemini-2.5-flash-lite")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertNil(body["temperature"])
        let toolBlocks = array(body["tools"])
        XCTAssertEqual(str(toolBlocks[0], "type"), "function")
        XCTAssertEqual(str(dict(toolBlocks[0]["function"]), "name"), "get_timeline")
    }

    func testBodyOmitsToolsWhenEmpty() {
        let body = OpenAIRequestBuilder.body(
            model: "m", maxTokens: 1, temperature: 0.2, enablePromptCache: false,
            system: "s", tools: [], turns: []
        )
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
    }

    // MARK: - SSE decode: tool_calls round-trip

    func testStreamedToolCallAcrossMultipleDeltas() throws {
        var decoder = OpenAISSEDecoder()
        var events: [AgentStreamEvent] = []

        // id + name arrive first, arguments stream as fragments, then finish_reason.
        events += try decoder.consume(line: #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_42","function":{"name":"add_clips"}}]}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"track"}}]}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"Index\":1}"}}]}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#)

        XCTAssertEqual(events, [
            .toolCall(id: "call_42", name: "add_clips", argumentsJSON: "{\"trackIndex\":1}"),
            .stop(.toolUse),
        ])
    }

    func testParallelToolCallsFlushSortedByIndex() throws {
        var decoder = OpenAISSEDecoder()
        var events: [AgentStreamEvent] = []
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{}"}}]}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{}"}}]}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)

        XCTAssertEqual(events, [
            .toolCall(id: "a", name: "first", argumentsJSON: "{}"),
            .toolCall(id: "b", name: "second", argumentsJSON: "{}"),
            .stop(.toolUse),
        ])
    }

    func testTextDeltasThenEndTurn() throws {
        var decoder = OpenAISSEDecoder()
        var events: [AgentStreamEvent] = []
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{"content":" world"}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(events, [.text("Hello"), .text(" world"), .stop(.endTurn)])
    }

    func testDoneAndNonDataLinesIgnored() throws {
        var decoder = OpenAISSEDecoder()
        XCTAssertEqual(try decoder.consume(line: ": keep-alive comment"), [])
        XCTAssertEqual(try decoder.consume(line: ""), [])
        XCTAssertEqual(try decoder.consume(line: "data: [DONE]"), [])
    }

    func testEmptyToolArgumentsDefaultToEmptyObject() throws {
        var decoder = OpenAISSEDecoder()
        var events: [AgentStreamEvent] = []
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"x","function":{"name":"undo"}}]}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        XCTAssertEqual(events, [.toolCall(id: "x", name: "undo", argumentsJSON: "{}"), .stop(.toolUse)])
    }

    func testMissingToolCallIdGetsSyntheticId() throws {
        var decoder = OpenAISSEDecoder()
        var events: [AgentStreamEvent] = []
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"undo","arguments":"{}"}}]}}]}"#)
        events += try decoder.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        XCTAssertEqual(events, [.toolCall(id: "call_0", name: "undo", argumentsJSON: "{}"), .stop(.toolUse)])
    }

    func testErrorChunkThrows() {
        var decoder = OpenAISSEDecoder()
        XCTAssertThrowsError(
            try decoder.consume(line: #"data: {"error":{"message":"rate limited","code":429}}"#)
        ) { error in
            XCTAssertEqual(error as? OpenAITranslationError, .stream("rate limited"))
        }
    }

    func testFinishReasonMapping() {
        XCTAssertEqual(OpenAISSEDecoder.stopReason("tool_calls"), .toolUse)
        XCTAssertEqual(OpenAISSEDecoder.stopReason("stop"), .endTurn)
        XCTAssertEqual(OpenAISSEDecoder.stopReason("length"), .maxTokens)
        XCTAssertEqual(OpenAISSEDecoder.stopReason("content_filter"), .refusal)
        XCTAssertEqual(OpenAISSEDecoder.stopReason("something_new"), .other)
    }
}
