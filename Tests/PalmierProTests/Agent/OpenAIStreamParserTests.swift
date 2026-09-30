import Foundation
import Testing
@testable import PalmierPro

/// Streaming behaviour of the OpenAI-compatible chat provider, which also serves every
/// user-supplied gateway. Kept apart from the endpoint persistence suite because the parser
/// has nothing to do with how a model is configured.
@Suite("OpenAI-compatible stream parser")
struct OpenAIStreamParserTests {
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
