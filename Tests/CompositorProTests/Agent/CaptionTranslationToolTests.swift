import AppKit
import CoreMedia
import Foundation
import Testing
@testable import CompositorPro

@Suite("Caption translation pipeline tool")
@MainActor
struct CaptionTranslationToolTests {

    private func makeHarness() -> ToolHarness {
        let harness = ToolHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        return harness
    }

    @Test("Translates direct script beats into target language with styled caption templates")
    func translateDirectBeats() async throws {
        let harness = makeHarness()

        let result = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "translate",
                "targetLanguage": "es",
                "captionStyle": "bold-pop",
                "beats": [
                    [
                        "beatId": "intro",
                        "text": "Welcome to the video",
                        "startFrame": 0,
                        "endFrame": 60,
                    ],
                    [
                        "beatId": "step1",
                        "text": "Step one",
                        "startFrame": 60,
                        "endFrame": 120,
                    ],
                ],
            ]) as? [String: Any]
        )

        let jobId = try #require(result["id"] as? String)
        #expect(!jobId.isEmpty)
        #expect(result["status"] as? String == "translated")
        #expect(result["targetLanguage"] as? String == "es")
        #expect(result["targetLanguageName"] as? String == "Spanish")
        #expect(result["captionStyle"] as? String == "bold-pop")

        let segments = try #require(result["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        #expect(segments[0]["beatId"] as? String == "intro")
        #expect(segments[0]["sourceText"] as? String == "Welcome to the video")
        #expect(segments[0]["translatedText"] as? String == "Bienvenidos al video")
        #expect(segments[0]["startFrame"] as? Int == 0)
        #expect(segments[0]["endFrame"] as? Int == 60)
        #expect(segments[0]["isApproved"] as? Bool == false)

        #expect(segments[1]["beatId"] as? String == "step1")
        #expect(segments[1]["translatedText"] as? String == "Paso uno")
    }

    @Test("Translates script beats from EditPlan with measured narration timing")
    func translateFromEditPlanWithNarrationTiming() async throws {
        let harness = makeHarness()

        let scriptBeats = [
            ScriptBeat(
                beatId: "hook_1",
                text: "Welcome to the video",
                purpose: "Opening hook"
            ),
            ScriptBeat(
                beatId: "cta_2",
                text: "Thanks for watching",
                purpose: "Closing call to action"
            ),
        ]
        let anchors = [
            NarrationTiming.Anchor(
                beatId: "hook_1",
                speechStart: try NarrationTime(CMTime(seconds: 0.5, preferredTimescale: 600)),
                speechEnd: try NarrationTime(CMTime(seconds: 2.5, preferredTimescale: 600))
            ),
            NarrationTiming.Anchor(
                beatId: "cta_2",
                speechStart: try NarrationTime(CMTime(seconds: 3.0, preferredTimescale: 600)),
                speechEnd: try NarrationTime(CMTime(seconds: 5.0, preferredTimescale: 600))
            ),
        ]
        let timing = NarrationTiming(
            revision: "rev1",
            sourceFingerprint: String(repeating: "a", count: 64),
            duration: try NarrationTime(CMTime(seconds: 6.0, preferredTimescale: 600)),
            anchors: anchors,
            unresolvedBeatIds: []
        )
        var plan = EditPlan(
            name: "Test Plan",
            timelineId: harness.editor.activeTimelineId,
            fps: 30,
            width: 1920,
            height: 1080,
            scriptBeats: scriptBeats
        )
        plan.id = "plan_test_42"
        plan.narrationTiming = timing
        harness.editor.editPlans.append(plan)

        let result = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "translate",
                "targetLanguage": "French",
                "planId": "plan_test_42",
                "captionStyle": "subtitle",
            ]) as? [String: Any]
        )

        let jobId = try #require(result["id"] as? String)
        #expect(!jobId.isEmpty)
        #expect(result["targetLanguage"] as? String == "fr")
        #expect(result["targetLanguageName"] as? String == "French")

        let segments = try #require(result["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        #expect(segments[0]["beatId"] as? String == "hook_1")
        #expect(segments[0]["startFrame"] as? Int == 15) // 0.5s * 30fps
        #expect(segments[0]["endFrame"] as? Int == 75)   // 2.5s * 30fps
        #expect(segments[0]["translatedText"] as? String == "Bienvenue dans la vidéo")

        #expect(segments[1]["beatId"] as? String == "cta_2")
        #expect(segments[1]["startFrame"] as? Int == 90)  // 3.0s * 30fps
        #expect(segments[1]["endFrame"] as? Int == 150)  // 5.0s * 30fps
        #expect(segments[1]["translatedText"] as? String == "Merci d'avoir regardé")
    }

    @Test("Applies custom translation dictionary overrides")
    func customTranslationsOverride() async throws {
        let harness = makeHarness()

        let result = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "translate",
                "targetLanguage": "ja",
                "beats": [
                    ["beatId": "b1", "text": "Welcome", "startFrame": 0, "endFrame": 30],
                ],
                "customTranslations": [
                    "b1": "特別なお知らせです",
                ],
            ]) as? [String: Any]
        )

        let segments = try #require(result["segments"] as? [[String: Any]])
        #expect(segments[0]["translatedText"] as? String == "特別なお知らせです")
    }

    @Test("Reviewing, editing, approving segments and atomic timeline application with single undo")
    func reviewApproveAndApplyWorkflow() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)

        let initialTrackCount = harness.editor.timeline.tracks.count

        // 1. Translate
        let transResult = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "translate",
                "targetLanguage": "de",
                "captionStyle": "clean",
                "beats": [
                    ["beatId": "seg1", "text": "Welcome to the video", "startFrame": 0, "endFrame": 50],
                    ["beatId": "seg2", "text": "See you next time", "startFrame": 60, "endFrame": 110],
                ],
            ]) as? [String: Any]
        )
        let jobId = try #require(transResult["id"] as? String)

        // 2. Read back
        let readResult = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "read",
                "jobId": jobId,
            ]) as? [String: Any]
        )
        #expect(readResult["id"] as? String == jobId)

        // 3. Review segment 1: modify text, adjust frames, approve
        let reviewResult = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "review",
                "jobId": jobId,
                "segmentId": "seg1",
                "translatedText": "Herzlich Willkommen!",
                "startFrame": 5,
                "endFrame": 55,
                "isApproved": true,
            ]) as? [String: Any]
        )
        #expect(reviewResult["status"] as? String == "partially_approved")
        let reviewedSegs = try #require(reviewResult["segments"] as? [[String: Any]])
        #expect(reviewedSegs[0]["translatedText"] as? String == "Herzlich Willkommen!")
        #expect(reviewedSegs[0]["startFrame"] as? Int == 5)
        #expect(reviewedSegs[0]["endFrame"] as? Int == 55)
        #expect(reviewedSegs[0]["isApproved"] as? Bool == true)

        // 4. Approve all
        let approveAllResult = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "approve_all",
                "jobId": jobId,
            ]) as? [String: Any]
        )
        #expect(approveAllResult["status"] as? String == "approved")

        // 5. Apply to timeline
        let applyResult = try #require(
            try await harness.runOK("translate_captions", args: [
                "action": "apply",
                "jobId": jobId,
                "trackName": "German Captions",
            ]) as? [String: Any]
        )
        #expect(applyResult["jobId"] as? String == jobId)
        #expect(applyResult["targetLanguage"] as? String == "de")
        #expect(applyResult["segmentCount"] as? Int == 2)
        #expect(applyResult["undoable"] as? Bool == true)

        // Verify dedicated caption track created on timeline
        #expect(harness.editor.timeline.tracks.count == initialTrackCount + 1)
        let captionTrack = harness.editor.timeline.tracks[0]
        #expect(captionTrack.name == "German Captions")
        #expect(captionTrack.clips.count == 2)

        let clip1 = captionTrack.clips[0]
        #expect(clip1.mediaType == .text)
        #expect(clip1.textContent == "Herzlich Willkommen!")
        #expect(clip1.startFrame == 5)
        #expect(clip1.durationFrames == 50)
        #expect(clip1.captionGroupId != nil)

        let clip2 = captionTrack.clips[1]
        #expect(clip2.mediaType == .text)
        #expect(clip2.textContent == "Bis zum nächsten Mal")
        #expect(clip2.startFrame == 60)
        #expect(clip2.durationFrames == 50)

        // 6. Verify single atomic undo
        #expect(undo.canUndo)
        undo.undo()
        #expect(harness.editor.timeline.tracks.count == initialTrackCount)

        // 7. Verify redo
        #expect(undo.canRedo)
        undo.redo()
        #expect(harness.editor.timeline.tracks.count == initialTrackCount + 1)
        #expect(harness.editor.timeline.tracks[0].clips.count == 2)
    }

    @Test("Validates unknown caption style and rejects invalid operations")
    func validationAndErrorHandling() async throws {
        let harness = makeHarness()

        // Unknown caption style
        let styleRes = await harness.runRaw("translate_captions", args: [
            "action": "translate",
            "targetLanguage": "es",
            "captionStyle": "non-existent-fantasy-style",
            "beats": [["text": "Hello"]],
        ])
        #expect(styleRes.isError)

        // Missing target language on translate
        let langRes = await harness.runRaw("translate_captions", args: [
            "action": "translate",
            "beats": [["text": "Hello"]],
        ])
        #expect(langRes.isError)

        // Job not found
        let notFoundRes = await harness.runRaw("translate_captions", args: [
            "action": "read",
            "jobId": "invalid-job-id",
        ])
        #expect(notFoundRes.isError)
    }
}
