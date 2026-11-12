import Foundation
import Testing
@testable import CompositorPro

@Suite("Targeted edit tool selection")
struct TargetedEditToolTests {
    @Test(arguments: [
        "Replace the clip on track 2 with the new take",
        "swap the media for this clip",
        "trim the first clip by 12 frames",
        "add captions to the timeline",
    ])
    func ordinaryEditsAreTargeted(request: String) {
        #expect(ToolDefinitions.isTargetedEdit(request))
    }

    @Test(arguments: [
        "Produce a 60 second documentary about this footage",
        "make me a video from these clips",
        "generate a video of a drone over the coast",
        "build the storyboard and then assemble the film",
        "use a design spec for the titles",
    ])
    func productionRequestsAreNotTargeted(request: String) {
        #expect(!ToolDefinitions.isTargetedEdit(request))
    }

    @Test("Editing subset excludes generation and planning schemas")
    func editingSubsetIsSmallerThanFullCatalog() {
        let editing = Set(ToolDefinitions.editingToolNames)
        #expect(editing.contains(.swapClipMedia))
        #expect(editing.contains(.getTimeline))
        #expect(!editing.contains(.generateVideo))
        #expect(!editing.contains(.producePlan))
        #expect(!editing.contains(.planEdit))
        #expect(editing.count < ToolName.allCases.count)
    }
}