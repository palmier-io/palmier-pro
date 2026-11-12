import Foundation
import Testing
@testable import CompositorPro

/// Streaming behaviour of the OpenAI-compatible chat provider, which also serves every
/// user-supplied gateway. Kept apart from the endpoint persistence suite because the parser
/// has nothing to do with how a model is configured.
@Suite("OpenAI-compatible stream parser")
struct OpenAIStreamParserTests {
    @Test func responsesParserSurfacesReasoningAndToolPreparationBeforeContent() throws {
        var parser = OpenAIStreamParser()
        #expect(try parser.consume(event: ["type": "response.output_item.added", "item": ["type": "reasoning"]]) ==
                [.activity(.reasoning)])
        #expect(try parser.consume(event: ["type": "response.output_item.added", "item": ["type": "function_call", "name": "get_timeline"]]) ==
                [.activity(.preparingTool("get_timeline"))])
        #expect(try parser.consume(event: ["type": "response.output_item.done", "item": [
            "type": "function_call", "call_id": "call_1", "name": "get_timeline", "arguments": "{}",
        ]]) == [.toolUseComplete(id: "call_1", name: "get_timeline", inputJSON: "{}")])
    }

    /// Regression: only `reasoning_content` was read, so an OpenRouter reasoning model produced
    /// no visible output at all and the panel showed activity dots for the whole think.
    @Test func parserSurfacesReasoningUnderEveryGatewaySpelling() throws {
        var openRouter = OpenAIChatCompletionsStreamParser()
        #expect(try openRouter.consume(line: #"data: {"choices":[{"delta":{"reasoning":"weighing options"}}]}"#)
            == [.reasoningSummaryDelta("weighing options")])

        var deepSeek = OpenAIChatCompletionsStreamParser()
        #expect(try deepSeek.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"weighing options"}}]}"#)
            == [.reasoningSummaryDelta("weighing options")])

        var structured = OpenAIChatCompletionsStreamParser()
        #expect(try structured.consume(line: """
            data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"step one"}]}}]}
            """) == [.reasoningSummaryDelta("step one")])

        // A gateway sending both spellings must not render the same thought twice.
        var both = OpenAIChatCompletionsStreamParser()
        #expect(try both.consume(line: """
            data: {"choices":[{"delta":{"reasoning":"once","reasoning_details":[{"text":"once"}]}}]}
            """) == [.reasoningSummaryDelta("once")])

        // Reasoning and answer still interleave in order.
        var interleaved = OpenAIChatCompletionsStreamParser()
        #expect(try interleaved.consume(line: #"data: {"choices":[{"delta":{"reasoning":"hmm","content":"Hi"}}]}"#)
            == [.reasoningSummaryDelta("hmm"), .textDelta("Hi")])
    }

    /// OpenRouter's usage chunk repeats `finish_reason`; it is an accounting frame, not a second
    /// terminal event, so the stop reason must not be emitted twice.
    @Test func parserTreatsTheOpenRouterUsageChunkAsAccountingOnly() throws {
        var parser = OpenAIChatCompletionsStreamParser()
        #expect(try parser.consume(line: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#)
            == [.textDelta("Hi")])
        let stops = try parser.consume(line: #"data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}]}"#)
        #expect(stops == [.messageStop(stopReason: .endTurn)])
        #expect(try parser.consume(line: #"data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"total_tokens":9}}"#) == [])
        #expect(try parser.consume(line: "data: [DONE]") == [])
    }
}

/// Reasoning effort reaches an OpenAI-compatible gateway. `.custom` used to offer only
/// `none`, so the picker had a single option and nothing was ever sent.
@Suite("OpenAI-compatible request body")
struct OpenAIChatCompletionsBodyTests {
    private func body(effort: AgentReasoningEffort) -> [String: Any] {
        OpenAIChatCompletionsRequestBody.build(
            modelID: "some/model",
            system: "",
            tools: [],
            messages: [],
            reasoningEffort: effort
        )
    }

    @Test func noEffortMeansNoReasoningFieldsAtAll() {
        let body = body(effort: .none)
        #expect(body["reasoning"] == nil)
        #expect(body["reasoning_effort"] == nil)
    }

    @Test func effortIsSentInBothGatewayDialects() {
        for effort in [AgentReasoningEffort.low, .medium, .high] {
            let body = body(effort: effort)
            #expect((body["reasoning"] as? [String: String])?["effort"] == effort.rawValue)
            #expect(body["reasoning_effort"] as? String == effort.rawValue)
        }
    }

    @Test func customModelsAdvertiseSelectableEfforts() {
        #expect(AgentModel.custom.supportedReasoningEfforts == [.low, .medium, .high])
        // The picker must never offer an effort the run settings will reject.
        #expect(AgentModel.custom.supportedReasoningEfforts.contains(AgentReasoningEffort.xHigh) == false)
    }
}
