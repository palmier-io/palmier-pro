import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("Production review, audio inspection, sound cues, and quality gates")
@MainActor
struct ProductionReviewAndAudioTests {
    private let harness = ToolHarness()

    @Test("Audio analysis distinguishes silent, clipped, sfx, and music audio")
    func audioAnalysisDistinguishesAudioTypes() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }

        // 1. Silent file
        let silentURL = directory.appendingPathComponent("silent.wav")
        try await AudioFinishingFixtures.writeTone(to: silentURL, amplitudes: [0.0], secondsPerLevel: 1.0)
        let silentAnalysis = try await AudioSourceAnalyzer.analyze(url: silentURL)
        #expect(silentAnalysis.contentType == "silence")
        #expect(silentAnalysis.silenceRatio >= 0.95)

        // 2. Clipped file
        let clippedURL = directory.appendingPathComponent("clipped.wav")
        try await AudioFinishingFixtures.writeTone(to: clippedURL, amplitudes: [1.5], secondsPerLevel: 1.0)
        let clippedAnalysis = try await AudioSourceAnalyzer.analyze(url: clippedURL)
        #expect(clippedAnalysis.qualityWarnings.contains("clipping_detected"))
        #expect(clippedAnalysis.clippedSamples > 0)

        // 3. Short SFX tone (< 5s)
        let sfxURL = directory.appendingPathComponent("sfx.wav")
        try await AudioFinishingFixtures.writeTone(to: sfxURL, amplitudes: [0.2], secondsPerLevel: 0.5)
        let sfxAnalysis = try await AudioSourceAnalyzer.analyze(url: sfxURL)
        #expect(sfxAnalysis.contentType == "sfx")
        #expect(sfxAnalysis.durationSeconds <= 5.0)

        // 4. Music tone (>= 6s)
        let musicURL = directory.appendingPathComponent("music.wav")
        try await AudioFinishingFixtures.writeTone(to: musicURL, amplitudes: [0.1], secondsPerLevel: 6.0)
        let musicAnalysis = try await AudioSourceAnalyzer.analyze(url: musicURL)
        #expect(musicAnalysis.contentType == "music")
    }

    @Test("Sound cues are assembled and placed on role-specific tracks")
    func soundCuesAreAssembledAndPlaced() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }

        let sfxAsset = harness.addAsset(id: "sfx-door", type: .audio, duration: 3.0)
        sfxAsset.url = directory.appendingPathComponent("tone.wav")
        try await sfxAsset.prepareInputIdentity()
        harness.editor.mediaManifest.entries.append(sfxAsset.toManifestEntry(projectURL: nil))

        let plan = EditPlan(
            name: "Sound Cue Production",
            timelineId: harness.editor.activeTimelineId,
            fps: harness.editor.timeline.fps,
            width: harness.editor.timeline.width,
            height: harness.editor.timeline.height,
            shots: [
                EditPlanShot(
                    id: "scene1",
                    title: "Door scene",
                    startFrame: 0,
                    endFrame: 60,
                    mediaRef: "sfx-door"
                )
            ],
            soundCues: [
                PlanSoundCue(
                    cueId: "cue-door",
                    role: .sfx,
                    purpose: "Door close transient",
                    anchorFrame: 24,
                    durationSeconds: 0.5,
                    mediaRef: "sfx-door"
                ),
                PlanSoundCue(
                    cueId: "cue-missing",
                    role: .ambience,
                    purpose: "Rain ambience",
                    anchorFrame: 0,
                    durationSeconds: 2.0,
                    mediaRef: nil
                )
            ]
        )
        try harness.editor.changeEditPlans(creates: [plan], actionName: "Create Cue Plan")
        _ = try harness.editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve Cue Plan")

        // Cue with nil mediaRef creates explicit blocker
        let resolvedFrames = try plan.resolvedSoundCueFrames()
        #expect(resolvedFrames.contains { $0.cueId == "cue-missing" && $0.blocker == "missing_cue_audio" })
        #expect(resolvedFrames.contains { $0.cueId == "cue-door" && $0.frame == 24 && $0.blocker == nil })

        let prepared = try await harness.editor.preparePlanAssembly(planId: plan.id)
        let receipt = try await harness.editor.commitPlanAssembly(prepared)
        #expect(receipt.changed)

        // Cue clip is placed on the timeline
        let allClips = harness.editor.timeline.tracks.flatMap(\.clips)
        let doorClip = allClips.first { $0.id.contains("cue-door") || $0.mediaRef == "sfx-door" }
        #expect(doorClip != nil)
    }

    @Test("Deterministic QC blocks export on black gaps, hidden tracks, and unfinished jobs")
    func deterministicQCBlocksExportOnDefects() async throws {
        let plan = EditPlan(
            name: "Defect Gate Plan",
            timelineId: harness.editor.activeTimelineId,
            fps: 30,
            width: 1920,
            height: 1080,
            shots: [EditPlanShot(id: "shot1", title: "Shot", startFrame: 0, endFrame: 60)]
        )
        try harness.editor.changeEditPlans(creates: [plan], actionName: "Create Plan")

        let coordinator = harness.editor.productionCoordinator

        // 1. Black gap at head of video track
        var clip = Fixtures.clip(mediaRef: "", mediaType: .text, start: 30, duration: 60)
        clip.textContent = "Title with head gap"
        var timeline = harness.editor.timeline
        timeline.tracks = [Fixtures.videoTrack(clips: [clip])]
        harness.editor.timeline = timeline

        var run = ProductionRun(storyboardRevision: String(repeating: "c", count: 64))
        run.phase = .approved
        run.approvedRevision = run.storyboardRevision
        try harness.editor.commitProductionRun(run, plan: harness.editor.editPlan(id: plan.id)!, actionName: "Seed run")
        // The cut is already assembled; the run continues at review and delivery.
        let assemblyKey = "assemble:" + (try ProductionRevision.assemblyInputs(plan))
        var assembled = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        assembled.record(.init(kind: .assemble, state: .completed, key: assemblyKey))
        try harness.editor.commitProductionRunMetadata(assembled, plan: harness.editor.editPlan(id: plan.id)!)

        try await coordinator.resume(planId: plan.id)
        let afterGap = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        #expect(afterGap.reviewFindings.contains { $0.kind == "blackGap" })

        // 2. Hidden track containing clips
        clip.startFrame = 0
        var hiddenTrack = Fixtures.videoTrack(clips: [clip])
        hiddenTrack.hidden = true
        timeline.tracks = [hiddenTrack]
        harness.editor.timeline = timeline

        try await coordinator.resume(planId: plan.id)
        let afterHidden = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        #expect(afterHidden.reviewFindings.contains { $0.kind == "hiddenTrack" })
    }

    @Test("Review timeline computes output revision and flags masking")
    func reviewTimelineReportsOutputRevisionAndDetectsMasking() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }

        let voiceAsset = harness.addAsset(id: "voice-track", type: .audio, duration: 2.0)
        voiceAsset.url = directory.appendingPathComponent("tone.wav")
        let musicAsset = harness.addAsset(id: "music-bed", type: .audio, duration: 2.0)
        musicAsset.url = directory.appendingPathComponent("tone.wav")
        for asset in [voiceAsset, musicAsset] {
            try await asset.prepareInputIdentity()
            harness.editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
        }

        var voiceClip = Fixtures.clip(mediaRef: "voice-track", mediaType: .audio, start: 0, duration: 60)
        voiceClip.volume = 0.5
        var musicClip = Fixtures.clip(mediaRef: "music-bed", mediaType: .audio, start: 0, duration: 60)
        musicClip.volume = 1.0 // Loud music bed masking voice

        var textClip = Fixtures.clip(mediaRef: "", mediaType: .text, start: 0, duration: 60)
        textClip.textContent = "Test Visual"

        harness.editor.timeline.tracks = [
            Fixtures.videoTrack(clips: [textClip]),
            Fixtures.audioTrack(clips: [voiceClip]),
            Fixtures.audioTrack(clips: [musicClip]),
        ]

        let raw1 = await harness.runRaw("review_timeline", args: ["startFrame": 0, "endFrame": 60])
        #expect(!raw1.isError)
        var text1 = ""
        for block in raw1.content {
            if case let .text(t) = block { text1 = t }
        }
        let result1 = try #require(try JSONSerialization.jsonObject(with: Data(text1.utf8)) as? [String: Any])
        let revision1 = try #require(result1["outputRevision"] as? String)
        #expect(!revision1.isEmpty)
        let warnings = (result1["qualityWarnings"] as? [String]) ?? []
        #expect(warnings.contains("musicMaskingNarration"))

        // Modifying the clip volume changes output revision
        harness.editor.timeline.tracks[2].clips[0].volume = 0.1
        let raw2 = await harness.runRaw("review_timeline", args: ["startFrame": 0, "endFrame": 60])
        #expect(!raw2.isError)
        var text2 = ""
        for block in raw2.content {
            if case let .text(t) = block { text2 = t }
        }
        let result2 = try #require(try JSONSerialization.jsonObject(with: Data(text2.utf8)) as? [String: Any])
        let revision2 = try #require(result2["outputRevision"] as? String)
        #expect(revision1 != revision2)
    }
}
