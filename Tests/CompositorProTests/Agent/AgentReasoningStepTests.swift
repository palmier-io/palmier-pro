import Foundation
import Testing
@testable import CompositorPro

@Suite("Agent reasoning step presentation")
struct AgentReasoningStepTests {
    @Test(arguments: [
        ("Checking the timeline", "Checking the timeline"),
        ("Checking the timeline\nThen the audio", "Checking the timeline"),
        ("\n\n  Checking the timeline  \n", "Checking the timeline"),
        ("", ""),
        ("\n \n", ""),
    ])
    func oneLineUsesFirstNonEmptyLine(text: String, expected: String) {
        #expect(AgentReasoningStep.oneLine(text) == expected)
    }

    @Test("An unfinished reasoning block is presented as in progress")
    func incompleteBlockIsInProgress() {
        let block = AgentContentBlock.thinking(text: "considering", signature: "")
        #expect(!AgentContentBlock.isReasoningComplete(block))
    }

    @Test("A signed reasoning block is presented as a completed step")
    func completeBlockIsStep() {
        let block = AgentContentBlock.thinking(text: "considered", signature: "sig")
        #expect(AgentContentBlock.isReasoningComplete(block))
        #expect(AgentReasoningStep.oneLine("considered") == "considered")
    }
}