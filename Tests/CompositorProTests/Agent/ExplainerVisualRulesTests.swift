import Testing
@testable import CompositorPro

@Suite("Explainer visual guidance")
struct ExplainerVisualRulesTests {
    private var guidance: String {
        AgentInstructions.serverInstructions.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func requiresSourceUniquenessRatherThanPlacementUniqueness() {
        #expect(guidance.contains("Never use the same image or video more than once"))
        #expect(guidance.contains("canonical source identity, not only clip IDs"))
        #expect(guidance.contains("inputs baked into composites"))
        #expect(guidance.contains("Audio and storyboard/review previews are outside"))
    }

    @Test func requiresFacelessFootageAndHonestInspectionCoverage() {
        #expect(guidance.contains("Do not use images or videos with people's faces revealed"))
        #expect(guidance.contains("reflections, photographs, and screens"))
        #expect(guidance.contains("sparse sampled frames do not certify"))
        #expect(guidance.contains("Unknown coverage is unresolved"))
    }

    @Test func storyboardApprovalPrecedesFullProductionWithoutRoutinePrompts() {
        #expect(guidance.contains("Obtain explicit user approval of that revision before final narration generation"))
        #expect(guidance.contains("Material changes require renewed"))
        #expect(guidance.contains("Storyboard approval never overrides visual uniqueness or face restrictions"))
    }
}
