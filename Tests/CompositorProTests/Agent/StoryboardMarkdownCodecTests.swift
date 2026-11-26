import Foundation
import Testing
@testable import CompositorPro

@Suite("Storyboard Markdown Codec")
@MainActor
struct StoryboardMarkdownCodecTests {

    private let sampleMarkdown = """
    # Storyboard: Product Launch Video

    ## Overview
    - **Goal:** Introduce the revolutionary AI video creation engine
    - **Duration:** 12.0s
    - **FPS:** 30
    - **Resolution:** 1920x1080
    - **Status:** proposed

    ---

    ### Beat 1 — Cold Open: Infinite Canvas
    - **Timecode:** 0:00 – 0:04
    - **Voiceover:** "Your AI agent already knows how to make videos."
    - **Visual Concept:** Camera drifts across infinite canvas with animating cards.
    - **Purpose:** Hook the audience in the opening seconds.
    - **SFX:** Ambient riser whoosh

    ### Beat 2 — The Format
    - **Timecode:** 0:04 – 0:08
    - **Voiceover:** "It just needs the right format. This is Compositor Pro."
    - **Pronunciation:** "It just needs the right format. This is Compositor Pro."
    - **Visual Concept:** Locks onto a single card, scales up to fill frame.
    - **Purpose:** Introduce the product identity.
    - **SFX:** UI click snap

    ### Beat 3 — The Engine
    - **Timecode:** 0:08 – 0:12
    - **Voiceover:** "Deterministic. Identical output, every time."
    - **Visual Concept:** Technical pipeline diagram drawing left to right.
    - **Purpose:** Establish technical credibility.
    - **Rights:** License: CC-BY-4.0 | Attribution: Compositor Team
    """

    @Test func parsesHyperFramesStoryboardMarkdown() throws {
        let plan = try StoryboardMarkdownCodec.parse(
            markdown: sampleMarkdown,
            timelineId: "timeline-1",
            fps: 30,
            width: 1920,
            height: 1080
        )

        #expect(plan.name == "Product Launch Video")
        #expect(plan.goal == "Introduce the revolutionary AI video creation engine")
        #expect(plan.shots.count == 3)
        #expect(plan.scriptBeats?.count == 3)
        #expect(plan.soundCues?.count == 2)

        let shot1 = plan.shots[0]
        #expect(shot1.title == "Cold Open: Infinite Canvas")
        #expect(shot1.startFrame == 0)
        #expect(shot1.endFrame == 120)
        #expect(shot1.notes == "Camera drifts across infinite canvas with animating cards.")
        #expect(shot1.narrationLink?.firstBeatId == "beat-1")

        let beat1 = try #require(plan.scriptBeats?[0])
        #expect(beat1.text == "Your AI agent already knows how to make videos.")
        #expect(beat1.purpose == "Hook the audience in the opening seconds.")

        let shot2 = plan.shots[1]
        #expect(shot2.title == "The Format")
        #expect(shot2.startFrame == 120)
        #expect(shot2.endFrame == 240)

        let shot3 = plan.shots[2]
        #expect(shot3.license == "CC-BY-4.0")
        #expect(shot3.attribution == "Compositor Team")
    }

    @Test func exportsEditPlanToStoryboardMarkdown() throws {
        let plan = try StoryboardMarkdownCodec.parse(
            markdown: sampleMarkdown,
            timelineId: "timeline-1",
            fps: 30
        )
        let exported = StoryboardMarkdownCodec.export(plan: plan)

        #expect(exported.contains("# Storyboard: Product Launch Video"))
        #expect(exported.contains("### Beat 1 — Cold Open: Infinite Canvas"))
        #expect(exported.contains("- **Timecode:** 0:00 – 0:04"))
        #expect(exported.contains("- **Voiceover:** \"Your AI agent already knows how to make videos.\""))
        #expect(exported.contains("- **SFX:** Ambient riser whoosh"))
        #expect(exported.contains("- **Rights:** License: CC-BY-4.0 | Attribution: Compositor Team"))
    }

    @Test func roundtripsPreservingPacingAndStructure() throws {
        let original = try StoryboardMarkdownCodec.parse(
            markdown: sampleMarkdown,
            timelineId: "timeline-1",
            fps: 30
        )
        let markdown = StoryboardMarkdownCodec.export(plan: original)
        let reloaded = try StoryboardMarkdownCodec.parse(
            markdown: markdown,
            timelineId: "timeline-1",
            fps: 30
        )

        #expect(reloaded.name == original.name)
        #expect(reloaded.shots.count == original.shots.count)
        #expect(reloaded.shots.map(\.startFrame) == original.shots.map(\.startFrame))
        #expect(reloaded.shots.map(\.endFrame) == original.shots.map(\.endFrame))
        #expect(reloaded.scriptBeats?.map(\.text) == original.scriptBeats?.map(\.text))
    }

    @Test func toolImportAndExportThroughPlanEdit() async throws {
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor)

        // 1. Import markdown storyboard via tool
        let importResult = await executor.execute(name: "plan_edit", args: [
            "action": "import_storyboard_markdown",
            "markdown": sampleMarkdown,
            "name": "Imported Product Video"
        ])
        #expect(!importResult.isError)

        guard let plan = editor.editPlans.first(where: { $0.name == "Imported Product Video" }) else {
            Issue.record("Plan not found in editor")
            return
        }
        #expect(plan.shots.count == 3)

        // 2. Export markdown storyboard via tool
        let exportResult = await executor.execute(name: "plan_edit", args: [
            "action": "export_storyboard_markdown",
            "planId": plan.id
        ])
        #expect(!exportResult.isError)
        #expect(exportResult.text.contains("# Storyboard: Imported Product Video"))
        #expect(exportResult.text.contains("### Beat 1 — Cold Open: Infinite Canvas"))
    }

    @Test func handlesRelativeDurationsAndMissingTimecodesGracefully() throws {
        let looseMarkdown = """
        # Storyboard: Minimal Plan

        ### Scene 1
        - **Duration:** 5s
        - **VO:** "Hello world."

        ### Scene 2
        - **VO:** "Second scene with default pacing."
        """

        let plan = try StoryboardMarkdownCodec.parse(
            markdown: looseMarkdown,
            timelineId: "timeline-1",
            fps: 30
        )

        #expect(plan.shots.count == 2)
        #expect(plan.shots[0].startFrame == 0)
        #expect(plan.shots[0].endFrame == 150) // 5s * 30fps
        #expect(plan.shots[1].startFrame == 150)
        #expect(plan.shots[1].endFrame > 150) // default 3.5s = 105 frames -> 255
    }
}

