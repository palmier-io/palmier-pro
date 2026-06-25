import Foundation
import Testing
@testable import PalmierPro

@Suite("OpenAI-compatible client — wire format")
struct OpenAICompatTests {

    private func sse(_ obj: [String: Any]) -> String {
        "data: " + String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func tok(_ event: AnthropicStreamEvent) -> String {
        switch event {
        case .textDelta(let s): "text:\(s)"
        case .toolUseComplete(let id, let name, let json): "tool:\(id):\(name):\(json)"
        case .messageStop(let reason): "stop:\(reason.rawValue)"
        }
    }

    private func decode(_ lines: [String]) -> (tokens: [String], error: String?) {
        var decoder = OpenAISSEDecoder()
        var out: [AnthropicStreamEvent] = []
        for line in lines {
            let step = decoder.consume(line)
            if let error = step.error { return (out.map(tok), error) }
            out += step.events
        }
        out += decoder.finish()
        return (out.map(tok), nil)
    }

    @Test func textDeltasThenStop() {
        let r = decode([
            sse(["choices": [["delta": ["content": "Hello"]]]]),
            sse(["choices": [["delta": ["content": " world"]]]]),
            sse(["choices": [["delta": [:], "finish_reason": "stop"]]]),
            "data: [DONE]",
        ])
        #expect(r.tokens == ["text:Hello", "text: world", "stop:end_turn"])
    }

    @Test func multiChunkToolCallAccumulation() {
        let r = decode([
            sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "type": "function", "function": ["name": "get_timeline", "arguments": ""]]]]]]]),
            sse(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "{\"a\":"]]]]]]]),
            sse(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "1}"]]]]]]]),
            sse(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
        ])
        #expect(r.tokens == ["tool:call_1:get_timeline:{\"a\":1}", "stop:tool_use"])
    }

    @Test func parallelToolCallsSortedByIndex() {
        let r = decode([
            sse(["choices": [["delta": ["tool_calls": [
                ["index": 1, "id": "c1", "type": "function", "function": ["name": "redo", "arguments": "{}"]],
                ["index": 0, "id": "c0", "type": "function", "function": ["name": "undo", "arguments": "{}"]],
            ]]]]]),
            sse(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
        ])
        #expect(r.tokens == ["tool:c0:undo:{}", "tool:c1:redo:{}", "stop:tool_use"])
    }

    @Test func danglingStreamEmitsEndTurn() {
        let r = decode([sse(["choices": [["delta": ["content": "hi"]]]])])
        #expect(r.tokens == ["text:hi", "stop:end_turn"])
    }

    @Test func lengthMapsToMaxTokens() {
        let r = decode([
            sse(["choices": [["delta": ["content": "x"]]]]),
            sse(["choices": [["delta": [:], "finish_reason": "length"]]]),
        ])
        #expect(r.tokens == ["text:x", "stop:max_tokens"])
    }

    @Test func errorEventSurfacesMessage() {
        #expect(decode([sse(["error": ["message": "boom"]])]).error == "boom")
    }

    @Test func requestBodyTranslation() {
        let body = OpenAIRequestBody.build(
            model: "m",
            maxTokens: 100,
            system: "sys",
            tools: [AnthropicToolSchema(name: "t", description: "d", inputSchema: ["type": "object"])],
            messages: [
                AnthropicMessage(role: .user, content: [["type": "text", "text": "hi"]]),
                AnthropicMessage(role: .assistant, content: [["type": "tool_use", "id": "call_9", "name": "get_media", "input": ["q": "sunset"]]]),
                AnthropicMessage(role: .user, content: [["type": "tool_result", "tool_use_id": "call_9", "content": [["type": "text", "text": "ok"]]]]),
                AnthropicMessage(role: .user, content: [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]]]),
            ]
        )
        let s = String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!

        #expect(s.contains("\"role\":\"system\""))
        #expect(s.contains("\"role\":\"tool\"") && s.contains("\"tool_call_id\":\"call_9\""))
        #expect(s.contains("\"tool_calls\"") && s.contains("\"name\":\"get_media\"") && s.contains("sunset"))
        #expect(s.contains("image_url") && s.contains("base64,AAAA"))  // JSON escapes '/' in image/png
        #expect(!s.contains("cache_control"))
        #expect(s.contains("\"type\":\"function\""))
        #expect(body["model"] as? String == "m")
        #expect(body["stream"] as? Bool == true)
    }
}
