import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("Pinned narration synthesis")
struct PinnedNarrationSynthesisTests {
    private func narrator() -> LocalSpeechNarrator {
        .init(engine: .system, voiceIdentifier: "voice-id", rate: 1.0, pitch: 1.0)
    }

    private func planWithProof(matches: Bool = true, tamper: String? = nil) -> EditPlan {
        let rev = "narr-rev"
        let fingerprint = String(repeating: "a", count: 64)
        let bytes = MediaInputIdentity(contentSHA256: fingerprint, byteCount: 48000)
        var plan = EditPlan(name: "Narrated", timelineId: "timeline", fps: 30, width: 1920, height: 1080,
                            scriptBeats: PlanNarrationFixtures.beats(),
                            narrationIntent: .init(language: "en-US", startFrame: 0, narrator: .localSpeech(narrator())),
                            narration: .init(mediaRef: "narration-audio"))
        plan.narrationRevision = rev
        let spoken = NarrationSpokenText.digest(beats: PlanNarrationFixtures.beats())
        let request = NarrationSynthesisRequest(planId: plan.id, timelineId: plan.timelineId, runId: "run",
                                                approvedRevision: "approved", narrationRevision: rev,
                                                engine: .system, voiceIdentifier: "voice-id", language: "en-US",
                                                rate: 1.0, pitch: 1.0, spokenTextDigest: spoken)
        var proof = NarrationSynthesisProof(requestDigest: request.digest, planId: plan.id, timelineId: plan.timelineId,
                                            runId: "run", approvedRevision: "approved", narrationRevision: rev,
                                            engine: .system, voiceIdentifier: "voice-id", language: "en-US",
                                            rate: 1.0, pitch: 1.0, spokenTextDigest: spoken,
                                            writtenFrames: 44100, insertedSilenceSeconds: 0.3,
                                            mediaRef: "narration-audio", installedIdentity: bytes)
        if tamper == "voice" { proof.voiceIdentifier = "other" }
        if tamper == "media" { proof.mediaRef = "other" }
        if tamper == "bytes" { proof.installedIdentity = .init(contentSHA256: String(repeating: "b", count: 64), byteCount: 1) }
        if !matches { proof.spokenTextDigest = String(repeating: "f", count: 64) }
        plan.narrationSynthesisProof = proof
        plan.narrationTiming = try? NarrationAlignment.align(beats: PlanNarrationFixtures.beats(), transcript: PlanNarrationFixtures.transcript(),
                                                             duration: try! NarrationTime(CMTime(value: 3, timescale: 1)), revision: rev, fingerprint: fingerprint)
        return plan
    }

    @Test func matchingProofClearsUnverifiedBlockerWhenTimingResolved() {
        let plan = planWithProof()
        let fingerprint = String(repeating: "a", count: 64)
        let entries: [String: MediaManifestEntry] = [
            "narration-audio": .init(id: "narration-audio", name: "n.wav", type: .audio, source: .project(relativePath: "Media/n.wav"),
                                     duration: 3, inputIdentity: .init(contentSHA256: fingerprint, byteCount: 48000)),
        ]
        let blockers = plan.narrationProductionBlockers(entries: entries, unavailable: [])
        #expect(!blockers.contains("unverified_synthesized_narration"))
        #expect(!blockers.contains("narration_timing_source_mismatch"))
    }

    @Test func tamperedOrMismatchedProofBlocksProduction() {
        let mismatched = planWithProof(matches: false)
        #expect(mismatched.narrationProductionBlockers(entries: [:], unavailable: []).contains("unverified_synthesized_narration"))
        let wrongVoice = planWithProof(tamper: "voice")
        #expect(wrongVoice.narrationProductionBlockers(entries: [:], unavailable: []).contains("unverified_synthesized_narration"))
        let wrongMedia = planWithProof(tamper: "media")
        #expect(wrongMedia.narrationProductionBlockers(entries: [:], unavailable: []).contains("narration_proof_media_mismatch"))
        let wrongBytes = planWithProof(tamper: "bytes")
        let fingerprint = String(repeating: "a", count: 64)
        let entries: [String: MediaManifestEntry] = [
            "narration-audio": .init(id: "narration-audio", name: "n.wav", type: .audio, source: .project(relativePath: "Media/n.wav"),
                                     duration: 3, inputIdentity: .init(contentSHA256: fingerprint, byteCount: 48000)),
        ]
        #expect(wrongBytes.narrationProductionBlockers(entries: entries, unavailable: []).contains("narration_proof_media_mismatch"))
    }

    @Test func localSpeechAttachmentRequiresMatchingProof() throws {
        var plan = planWithProof()
        let rev = String(repeating: "c", count: 64)
        plan.productionRun = ProductionRun(phase: .approved, storyboardRevision: rev, approvedRevision: rev)
        let identity = MediaInputIdentity(contentSHA256: String(repeating: "a", count: 64), byteCount: 48000)
        try plan.validateNarrationAttachment(identity: identity)
        var bad = plan
        bad.narrationSynthesisProof?.voiceIdentifier = "different"
        #expect(throws: EditPlanValidationError.self) { try bad.validateNarrationAttachment(identity: identity) }
    }

    @Test @MainActor func materialNarrationChangeClearsSynthesisProof() throws {
        let harness = ToolHarness()
        var plan = planWithProof()
        plan.id = "p1"
        plan.timelineId = harness.editor.activeTimelineId
        plan.fps = harness.editor.timeline.fps
        plan.width = harness.editor.timeline.width
        plan.height = harness.editor.timeline.height
        plan.productionRun = nil
        harness.editor.editPlans = [plan]
        var updated = plan
        updated.scriptBeats?[0].text = "Changed claim."
        _ = try harness.editor.changeEditPlans(updates: [updated], actionName: "Edit")
        let stored = try #require(harness.editor.editPlan(id: "p1"))
        #expect(stored.narrationSynthesisProof == nil)
        #expect(stored.narrationTiming == nil)
        #expect(stored.narrationRevision != plan.narrationRevision)
    }
}
