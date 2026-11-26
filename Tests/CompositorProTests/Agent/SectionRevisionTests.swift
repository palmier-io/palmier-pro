import CoreMedia
import Foundation
import Testing
@testable import CompositorPro

@Suite("Section revision dependencies")
struct SectionRevisionTests {
    private func planWithSection() throws -> EditPlan {
        var plan = EditPlan(name: "Plan", timelineId: "tl", fps: 30, width: 1920, height: 1080)
        plan.sections = [EditPlanSection(id: "sec-1", title: "Intro", summary: "Hook",
                                         startFrame: 0, endFrame: 90)]
        plan.scriptBeats = [
            ScriptBeat(beatId: "b1", text: "First line", purpose: "hook"),
            ScriptBeat(beatId: "b2", text: "Second line", purpose: "context"),
        ]
        plan.narrationRevision = UUID().uuidString
        plan.sections[0].narrationLink = SceneNarrationLink(firstBeatId: "b1", lastBeatId: "b1")
        return plan
    }

    @Test("Revising a section updates its linked beat and invalidates derived timing")
    func revisionInvalidatesTiming() throws {
        var plan = try planWithSection()
        plan.narrationTiming = NarrationTiming(
            revision: try #require(plan.narrationRevision),
            sourceFingerprint: String(repeating: "a", count: 64),
            duration: try NarrationTime(CMTime(seconds: 5, preferredTimescale: 600)),
            anchors: [], unresolvedBeatIds: []
        )
        let result = try plan.reviseSection(
            sectionId: "sec-1", title: "Intro v2", summary: "New hook",
            beatText: ["b1": "Rewritten first line"], startFrame: nil, endFrame: nil
        )
        #expect(result["changed"] as? Bool == true)
        let updated = try #require(result["updatedBeatIds"] as? [String])
        #expect(updated == ["b1"])
        #expect(plan.sections[0].title == "Intro v2")
        #expect(plan.scriptBeats?.first?.text == "Rewritten first line")
        #expect(plan.narrationTiming == nil, "derived timing must be rebuilt, not reused")
    }

    @Test("An unchanged revision is a no-op")
    func noOpRevision() throws {
        var plan = try planWithSection()
        let before = plan
        let result = try plan.reviseSection(
            sectionId: "sec-1", title: nil, summary: nil, beatText: nil, startFrame: nil, endFrame: nil
        )
        #expect(result["changed"] as? Bool == false)
        #expect(plan == before)
    }

    @Test("Revising an unknown section is refused")
    func unknownSectionRefused() throws {
        var plan = try planWithSection()
        #expect(throws: EditPlanValidationError.self) {
            _ = try plan.reviseSection(sectionId: "missing", title: nil, summary: nil,
                                       beatText: nil, startFrame: nil, endFrame: nil)
        }
    }
}