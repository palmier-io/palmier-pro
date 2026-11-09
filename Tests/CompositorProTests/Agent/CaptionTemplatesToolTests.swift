import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Caption template library by social format tool")
@MainActor
struct CaptionTemplatesToolTests {

    private func makeHarnessWithCaptions(count: Int = 3) -> (ToolHarness, String) {
        let harness = ToolHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)

        let trackIndex = harness.editor.insertTrack(at: 0, type: .video)
        let captionGroupId = UUID().uuidString

        for i in 0..<count {
            var clip = Clip(
                mediaRef: "",
                mediaType: .text,
                sourceClipType: .text,
                startFrame: i * 30,
                durationFrames: 25,
                textContent: "Caption line \(i + 1)"
            )
            clip.captionGroupId = captionGroupId
            clip.textStyle = TextStyle(fontName: "Helvetica", fontSize: 40)
            clip.transform.centerY = 0.5
            harness.editor.timeline.tracks[trackIndex].clips.append(clip)
        }

        return (harness, captionGroupId)
    }

    @Test("Lists caption templates filtered by vertical 9:16 format (Reels, TikTok, YouTube Shorts)")
    func listTemplatesVertical() async throws {
        let harness = ToolHarness()

        let result = try #require(
            try await harness.runOK("caption_templates", args: [
                "action": "list",
                "format": "vertical",
            ]) as? [String: Any]
        )

        let templates = try #require(result["templates"] as? [[String: Any]])
        #expect(!templates.isEmpty)
        #expect(result["formatFilter"] as? String == "vertical")

        for t in templates {
            #expect(t["format"] as? String == "vertical_9_16")
            let label = try #require(t["formatLabel"] as? String)
            #expect(label.contains("9:16"))
            let platforms = try #require(t["targetPlatforms"] as? [String])
            #expect(platforms.contains("instagramReels") || platforms.contains("tiktokShorts"))

            let thumb = try #require(t["previewThumbnail"] as? [String: Any])
            #expect(thumb["aspectRatio"] as? String == "9:16")
            #expect(thumb["badgeLabel"] as? String == "9:16")
        }

        let ids = templates.compactMap { $0["id"] as? String }
        #expect(ids.contains("bold-pop"))
        #expect(ids.contains("karaoke"))
        #expect(ids.contains("one-word"))
        #expect(ids.contains("neon"))
        #expect(ids.contains("beast"))
    }

    @Test("Lists caption templates filtered by horizontal 16:9 format (YouTube)")
    func listTemplatesHorizontal() async throws {
        let harness = ToolHarness()

        let result = try #require(
            try await harness.runOK("caption_templates", args: [
                "action": "list",
                "format": "youtube",
            ]) as? [String: Any]
        )

        let templates = try #require(result["templates"] as? [[String: Any]])
        #expect(!templates.isEmpty)

        for t in templates {
            #expect(t["format"] as? String == "horizontal_16_9")
            let label = try #require(t["formatLabel"] as? String)
            #expect(label.contains("16:9"))

            let thumb = try #require(t["previewThumbnail"] as? [String: Any])
            #expect(thumb["aspectRatio"] as? String == "16:9")
        }

        let ids = templates.compactMap { $0["id"] as? String }
        #expect(ids.contains("subtitle"))
        #expect(ids.contains("clean"))
        #expect(ids.contains("magazine"))
        #expect(ids.contains("editorial"))
    }

    @Test("Gets individual template details")
    func getTemplateDetails() async throws {
        let harness = ToolHarness()

        let result = try #require(
            try await harness.runOK("caption_templates", args: [
                "action": "get",
                "templateId": "bold-pop",
            ]) as? [String: Any]
        )

        #expect(result["id"] as? String == "bold-pop")
        #expect(result["displayName"] as? String == "Bold Pop")
        #expect(result["fontName"] as? String == "Anton")
        #expect(result["animationPreset"] as? String == "popIn")
        #expect(result["format"] as? String == "vertical_9_16")

        let thumb = try #require(result["previewThumbnail"] as? [String: Any])
        #expect(thumb["badgeLabel"] as? String == "9:16")
    }

    @Test("Applies chosen social format template across all project captions in one atomic undo")
    func applyTemplateToAllCaptions() async throws {
        let (harness, _) = makeHarnessWithCaptions(count: 3)
        let undo = UndoManager()
        harness.editor.undo.attach(undo)

        let result = try #require(
            try await harness.runOK("caption_templates", args: [
                "action": "apply",
                "templateId": "bold-pop",
            ]) as? [String: Any]
        )

        #expect(result["templateId"] as? String == "bold-pop")
        #expect(result["templateName"] as? String == "Bold Pop")
        #expect(result["appliedClipCount"] as? Int == 3)
        #expect(result["undoable"] as? Bool == true)

        let clips = harness.editor.timeline.tracks[0].clips
        #expect(clips.count == 3)

        for clip in clips {
            #expect(clip.textStyle?.fontName == "Anton")
            #expect(clip.textAnimation?.preset == .popIn)
            // Vertical 9:16 safe area clears bottom interface
            #expect(clip.transform.centerY == 0.72)
        }

        // Test single atomic undo
        #expect(undo.canUndo)
        undo.undo()

        for clip in harness.editor.timeline.tracks[0].clips {
            #expect(clip.textStyle?.fontName == "Helvetica")
            #expect(clip.transform.centerY == 0.5)
        }

        // Test redo
        #expect(undo.canRedo)
        undo.redo()

        for clip in harness.editor.timeline.tracks[0].clips {
            #expect(clip.textStyle?.fontName == "Anton")
            #expect(clip.transform.centerY == 0.72)
        }
    }

    @Test("Applies horizontal YouTube template with 16:9 lower-third positioning")
    func applyHorizontalYouTubeTemplate() async throws {
        let (harness, _) = makeHarnessWithCaptions(count: 2)

        let result = try #require(
            try await harness.runOK("caption_templates", args: [
                "action": "apply",
                "templateId": "subtitle",
                "format": "youtube",
            ]) as? [String: Any]
        )

        #expect(result["templateId"] as? String == "subtitle")
        #expect(result["appliedClipCount"] as? Int == 2)
        #expect(result["centerYRatio"] as? Double == 0.84)

        for clip in harness.editor.timeline.tracks[0].clips {
            #expect(clip.textStyle?.fontName == "Inter")
            #expect(clip.transform.centerY == 0.84)
        }
    }

    @Test("Validates unknown template and handles errors gracefully")
    func validationAndErrorHandling() async throws {
        let harness = ToolHarness()

        // Unknown template on get
        let res1 = await harness.runRaw("caption_templates", args: [
            "action": "get",
            "templateId": "non-existent-template",
        ])
        #expect(res1.isError)

        // Missing templateId on apply
        let res2 = await harness.runRaw("caption_templates", args: [
            "action": "apply",
        ])
        #expect(res2.isError)

        // Apply on empty timeline
        let res3 = await harness.runRaw("caption_templates", args: [
            "action": "apply",
            "templateId": "bold-pop",
        ])
        #expect(res3.isError)
    }
}

