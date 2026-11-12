import Foundation
import Testing
@testable import CompositorPro

@Suite("Section revision through the tool path")
@MainActor
struct SectionRevisionToolTests {
    private func harnessWithPlan() throws -> (ToolHarness, String) {
        let harness = ToolHarness()
        let plan = EditPlan(
            name: "Plan", timelineId: harness.editor.timeline.id,
            fps: 30, width: 1920, height: 1080
        )
        harness.editor.editPlans = [plan]
        return (harness, plan.id)
    }

    @Test("A section revision with linked beat text commits through the shared operation")
    func revisionCommits() async throws {
        let (harness, planId) = try harnessWithPlan()
        // Seed a section and beat directly, then drive the tool path.
        var plan = try #require(harness.editor.editPlan(id: planId))
        plan.sections = [EditPlanSection(id: "sec-1", title: "Intro", summary: "Hook",
                                         startFrame: 0, endFrame: 90)]
        plan.scriptBeats = [
            ScriptBeat(beatId: "b1", text: "First", purpose: "hook"),
            ScriptBeat(beatId: "b2", text: "Second", purpose: "context"),
        ]
        plan.narrationRevision = UUID().uuidString
        plan.sections[0].narrationLink = SceneNarrationLink(firstBeatId: "b1", lastBeatId: "b1")
        plan = try EditPlan.validatedNew(plan, timelineId: plan.timelineId, fps: 30,
                                         width: 1920, height: 1080, existingCount: 0)
        harness.editor.editPlans = [plan]

        let result = try await harness.runOK("plan_edit", args: [
            "action": "revise_section",
            "planId": planId,
            "sectionId": "sec-1",
            "title": "Intro v2",
            "beatText": ["b1": "Rewritten"],
        ])
        let dict = try #require(result as? [String: Any])
        let revision = try #require(dict["reviseSection"] as? [String: Any])
        #expect(revision["changed"] as? Bool == true)
        let stored = try #require(harness.editor.editPlan(id: planId))
        #expect(stored.sections.first?.title == "Intro v2")
        #expect(stored.scriptBeats?.first?.text == "Rewritten")
        #expect(stored.narrationTiming == nil)
    }

    @Test("Revising an unknown section is refused")
    func unknownSectionRefused() async throws {
        let (harness, planId) = try harnessWithPlan()
        let result = await harness.runRaw("plan_edit", args: [
            "action": "revise_section", "planId": planId, "sectionId": "missing",
        ])
        #expect(result.isError)
    }
}
