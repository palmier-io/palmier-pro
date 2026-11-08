import Foundation
import Testing
@testable import CompositorPro

struct NarrationIntentTests {
    @Test(arguments: ["language", "start", "engine", "voice", "rate", "pitch", "script", "pronunciation", "recording", "recording-bytes"])
    func materialNarrationChangesInvalidateApprovedIntent(change: String) throws {
        var original = EditPlan(name: "Intent", timelineId: "timeline", fps: 30, width: 1920, height: 1080,
            scriptBeats: PlanNarrationFixtures.beats(), narrationIntent: .init(language: "en-US", startFrame: 0,
                narrator: .localSpeech(.init(engine: .system, voiceIdentifier: "exact-voice", rate: 1, pitch: 1))))
        let revision = String(repeating: "a", count: 64)
        original.productionRun = ProductionRun(phase: .approved, storyboardRevision: revision, approvedRevision: revision)
        if change == "recording-bytes" {
            original.narrationIntent?.narrator = .recording(.init(mediaRef: "recording",
                identity: .init(contentSHA256: revision, byteCount: 10)))
        }
        var changed = original
        var speech = LocalSpeechNarrator(engine: .system, voiceIdentifier: "exact-voice", rate: 1, pitch: 1)
        switch change {
        case "language": changed.narrationIntent?.language = "en-GB"
        case "start": changed.narrationIntent?.startFrame = 1
        case "script": changed.scriptBeats?[0].text = "Changed script."
        case "pronunciation": changed.scriptBeats?[0].spokenText = "Changed pronunciation."
        case "recording", "recording-bytes":
            changed.narrationIntent?.narrator = .recording(.init(mediaRef: "recording",
                identity: .init(contentSHA256: String(repeating: "b", count: 64), byteCount: 10)))
        default:
            switch change {
            case "engine":
                speech.engine = .piper
                speech.modelIdentity = .init(contentSHA256: String(repeating: "b", count: 64), byteCount: 10)
                speech.configurationIdentity = .init(contentSHA256: String(repeating: "c", count: 64), byteCount: 20)
            case "voice": speech.voiceIdentifier = "different-voice"
            case "rate": speech.rate = 1.2
            default: speech.pitch = 1.2
            }
            changed.narrationIntent?.narrator = .localSpeech(speech)
        }
        #expect(!changed.hasSameStoryboardIntent(as: original))
        changed.invalidateStoryboardApproval(comparedTo: original)
        #expect(changed.productionRun?.phase == .stale)
        #expect(changed.productionRun?.approvedRevision == nil)
        #expect(original.productionRun?.approvedRevision == revision)
    }

    @Test(arguments: ["attach", "replace", "timing", "revision"])
    func derivedNarrationArtifactsDoNotChangeStoryboardIntent(change: String) throws {
        var original = EditPlan(name: "Artifact", timelineId: "timeline", fps: 30, width: 1920, height: 1080,
            scriptBeats: PlanNarrationFixtures.beats(), narrationIntent: .init(language: "en", startFrame: 0),
            narration: change == "attach" ? nil : .init(mediaRef: "original"))
        let revision = String(repeating: "a", count: 64)
        original.productionRun = ProductionRun(phase: .approved, storyboardRevision: revision, approvedRevision: revision)
        var changed = original
        switch change {
        case "attach", "replace": changed.narration = .init(mediaRef: "replacement")
        case "timing": changed.narrationTiming = try PlanNarrationFixtures.timing(revision: #require(changed.narrationRevision))
        default: changed.narrationRevision = UUID().uuidString
        }
        changed.invalidateStoryboardApproval(comparedTo: original)
        #expect(changed.storyboardIntent == original.storyboardIntent)
        #expect(changed.productionRun == original.productionRun)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, 2.1])
    func invalidSpeechDeliveryIsRefused(value: Double) {
        #expect(throws: EditPlanValidationError.self) {
            _ = try LocalSpeechNarrator(engine: .system, voiceIdentifier: "voice", rate: value, pitch: 1).validated()
        }
        #expect(throws: EditPlanValidationError.self) {
            _ = try LocalSpeechNarrator(engine: .system, voiceIdentifier: "voice", rate: 1, pitch: value).validated()
        }
    }

    @Test func piperCannotPromiseUnsupportedPitch() {
        let identity = MediaInputIdentity(contentSHA256: String(repeating: "a", count: 64), byteCount: 10)
        #expect(throws: EditPlanValidationError.self) {
            _ = try LocalSpeechNarrator(engine: .piper, voiceIdentifier: "voice", rate: 1, pitch: 1.2,
                modelIdentity: identity, configurationIdentity: identity).validated()
        }
    }

    @Test func unknownVoiceCannotApproveAndGenericMetadataCannotProveSpeech() async throws {
        var plan = EditPlan(name: "Unknown narrator", timelineId: "timeline", fps: 30, width: 1920, height: 1080,
            scriptBeats: PlanNarrationFixtures.beats(), narrationIntent: .init(language: "en-US", startFrame: 0,
                narrator: .localSpeech(.init(engine: .system, voiceIdentifier: "not-an-installed-voice", rate: 1, pitch: 1))))
        let report = try await StoryboardResolver.resolve(plan: plan, manifest: MediaManifest())
        #expect(report.approvalBlockers.contains("unavailable_narrator_intent"))
        #expect(!report.canApprove)
        let revision = String(repeating: "a", count: 64)
        plan.productionRun = ProductionRun(phase: .approved, storyboardRevision: revision, approvedRevision: revision)
        plan.narration = .init(mediaRef: "generic-speech")
        let identity = MediaInputIdentity(contentSHA256: revision, byteCount: 10)
        #expect(throws: EditPlanValidationError.self) { try plan.validateNarrationAttachment(identity: identity) }
        #expect(plan.narrationProductionBlockers(entries: [:], unavailable: []).contains("unverified_synthesized_narration"))
    }
}

private actor NarrationIdentityGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Recording narrator validation")
@MainActor
struct RecordingNarratorValidationTests {
    @Test func suppliedRecordingIntentMeasuresBytesWithoutAttachingAndRepeatsWithoutUndo() async throws {
        try await withRecording { harness, asset in
            let plan = try #require(harness.editor.editPlans.first)
            let identity = try #require(asset.inputIdentity)
            #expect(plan.narration == nil)
            #expect(plan.narrationIntent?.narrator == .recording(.init(mediaRef: asset.id, identity: identity)))
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let repeated = try await harness.editor.setPlanNarrationIntent(planId: plan.id,
                request: .init(language: "en", startFrame: 0, narrator: .init(kind: "recording", mediaRef: asset.id)))
            #expect(repeated.updated.isEmpty)
            #expect(harness.editor.editPlans == [plan])
            #expect(!undo.canUndo)
        }
    }

    @Test func matchingAttachmentPreservesReviewAndUndoesAsOneAction() async throws {
        try await withRecording { harness, asset in
            let planId = try #require(harness.editor.editPlans.first?.id)
            let board = try await harness.editor.prepareStoryboard(planId: planId)
            let before = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let attached = try await harness.editor.attachPlanNarration(planId: planId, mediaRef: asset.id)
            #expect(attached.updated.count == 1)
            let current = try #require(harness.editor.editPlan(id: planId))
            #expect(current.productionRun == before.first?.productionRun)
            #expect(current.narration?.mediaRef == asset.id)
            #expect(try await harness.editor.storyboardReport(planId: planId).revision == board.revision)
            undo.undo()
            #expect(harness.editor.editPlans == before)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(harness.editor.editPlans == [current])
            undo.removeAllActions()
            let repeated = try await harness.editor.attachPlanNarration(planId: planId, mediaRef: asset.id)
            #expect(repeated.updated.isEmpty)
            #expect(!undo.canUndo)
            var detached = current
            detached.narration = nil
            let prepared = try await harness.editor.preparePlanNarrationChange(detached)
            try harness.editor.changeEditPlans(updates: [prepared.plan], actionName: "Detach", narrationValidation: prepared.validation)
            undo.undo()
            #expect(harness.editor.editPlans == [current])
            #expect(!undo.canUndo)
        }
    }

    @Test func mismatchedRecordingCannotAttachOrChangeUndo() async throws {
        try await withRecording { harness, _ in
            let directory = try await PlanNarrationFixtures.makeAudio(seconds: 4)
            do {
                let other = harness.addAsset(id: "different-recording", type: .audio, duration: 4)
                other.url = directory.appendingPathComponent("voice.wav")
                try await other.prepareInputIdentity()
                harness.editor.mediaManifest.entries.append(other.toManifestEntry(projectURL: nil))
                let planId = try #require(harness.editor.editPlans.first?.id)
                _ = try await harness.editor.prepareStoryboard(planId: planId)
                let before = harness.editor.editPlans
                let undo = UndoManager()
                harness.editor.undo.attach(undo)
                do {
                    _ = try await harness.editor.attachPlanNarration(planId: planId, mediaRef: other.id)
                    Issue.record("Different recording was attached.")
                } catch { #expect(error is EditPlanValidationError) }
                #expect(harness.editor.editPlans == before)
                #expect(!undo.canUndo)
            } catch {
                try await PlanNarrationFixtures.remove(directory)
                throw error
            }
            try await PlanNarrationFixtures.remove(directory)
        }
    }

    @Test(arguments: ["attachment", "narrator"])
    func rawManagedChangesCannotBypassByteValidation(change: String) async throws {
        try await withRecording { harness, asset in
            let planId = try #require(harness.editor.editPlans.first?.id)
            _ = try await harness.editor.prepareStoryboard(planId: planId)
            let before = harness.editor.editPlans
            var candidate = try #require(before.first)
            if change == "attachment" { candidate.narration = .init(mediaRef: asset.id) }
            else {
                candidate.narrationIntent?.narrator = .recording(.init(mediaRef: asset.id,
                    identity: .init(contentSHA256: String(repeating: "f", count: 64), byteCount: 10)))
            }
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            #expect(throws: EditPlanValidationError.self) {
                try harness.editor.changeEditPlans(updates: [candidate], actionName: "Unchecked attachment")
            }
            #expect(harness.editor.editPlans == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func identicalByteAliasCanAttachWithoutChangingAuthoredRecording() async throws {
        try await withRecording { harness, asset in
            let planId = try #require(harness.editor.editPlans.first?.id)
            let alias = harness.addAsset(id: "recording-alias", type: .audio, duration: 3)
            alias.url = asset.url
            try await alias.prepareInputIdentity()
            harness.editor.mediaManifest.entries.append(alias.toManifestEntry(projectURL: nil))
            _ = try await harness.editor.prepareStoryboard(planId: planId)
            let before = try #require(harness.editor.editPlan(id: planId))
            _ = try await harness.editor.attachPlanNarration(planId: planId, mediaRef: alias.id)
            let current = try #require(harness.editor.editPlan(id: planId))
            #expect(current.narration?.mediaRef == alias.id)
            #expect(current.narrationIntent == before.narrationIntent)
            #expect(current.productionRun == before.productionRun)
        }
    }

    @Test func recordingRelinkInvalidatesReviewContextBeforeAttachment() async throws {
        try await withRecording { harness, asset in
            let planId = try #require(harness.editor.editPlans.first?.id)
            let before = harness.editor.storyboardPreviewContext(planId: planId)
            #expect(before.plan?.narration == nil)
            #expect(before.sources[asset.id]?.url == asset.url)
            asset.url = asset.url.appendingPathExtension("relinked")
            #expect(harness.editor.storyboardPreviewContext(planId: planId) != before)
        }
    }

    @Test func measurementForDifferentRecordingCannotCommitTimingOrUndo() async throws {
        try await withRecording { harness, asset in
            let planId = try #require(harness.editor.editPlans.first?.id)
            _ = try await harness.editor.prepareStoryboard(planId: planId)
            _ = try await harness.editor.attachPlanNarration(planId: planId, mediaRef: asset.id)
            let session = try PlanNarrationSession(editor: harness.editor, planId: planId)
            let timing = try PlanNarrationFixtures.timing(revision: #require(session.plan.narrationRevision))
            let before = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            #expect(throws: EditPlanValidationError.self) {
                try harness.editor.commitPlanNarrationTiming(timing, session: session)
            }
            #expect(harness.editor.editPlans == before)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: ["cancel", "plan", "project", "timeline", "selection", "asset", "asset-return", "identity", "duration", "file", "failure"])
    func canceledFailedOrStaleAttachmentCannotCommit(change: String) async throws {
        try await withRecording { harness, asset in
            let planId = try #require(harness.editor.editPlans.first?.id)
            _ = try await harness.editor.prepareStoryboard(planId: planId)
            var candidate = try #require(harness.editor.editPlan(id: planId))
            candidate.narration = .init(mediaRef: asset.id)
            let gate = NarrationIdentityGate()
            let task = Task {
                let prepared = try await harness.editor.preparePlanNarrationChange(candidate) { url in
                    await gate.hold()
                    if change == "failure" { throw CocoaError(.fileReadUnknown) }
                    return try await MediaInputIdentityService.shared.identify(url, force: true)
                }
                return try harness.editor.changeEditPlans(updates: [prepared.plan], actionName: "Attach", narrationValidation: prepared.validation)
            }
            await gate.waitUntilStarted()
            do {
                switch change {
                case "cancel": task.cancel()
                case "plan":
                    var current = try #require(harness.editor.editPlan(id: planId))
                    current.scriptBeats?[0].text = "Concurrent edit."
                    try harness.editor.changeEditPlans(updates: [current], actionName: "Edit")
                case "project": harness.editor.projectURL = asset.url.appendingPathComponent("different.palmier")
                case "timeline": harness.editor.timeline.width += 1
                case "selection": harness.editor.selectedMediaAssetIds = [asset.id]
                case "asset": asset.url = asset.url.appendingPathExtension("relinked")
                case "asset-return": Self.relinkAndRestore(asset)
                case "identity": asset.inputIdentity = nil
                case "duration": asset.duration = 0
                case "file": try await Self.changeBytes(asset.url)
                default: break
                }
            } catch {
                task.cancel()
                await gate.finish()
                _ = await task.result
                throw error
            }
            let before = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            await gate.finish()
            do { _ = try await task.value; Issue.record("Invalid attachment committed.") }
            catch { #expect(change != "cancel" || error is CancellationError) }
            #expect(harness.editor.editPlans == before)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: [false, true])
    func preparedRecordingChangeRejectsRestoredSourceBeforeCommit(attachment: Bool) async throws {
        try await withRecording { harness, asset in
            let planId = try #require(harness.editor.editPlans.first?.id)
            if !attachment {
                _ = try await harness.editor.setPlanNarrationIntent(planId: planId,
                    request: .init(language: "en", startFrame: 0))
            }
            _ = try await harness.editor.prepareStoryboard(planId: planId)
            var candidate = try #require(harness.editor.editPlan(id: planId))
            if attachment { candidate.narration = .init(mediaRef: asset.id) }
            let prepared = try await harness.editor.preparePlanNarrationChange(candidate,
                intentRequest: attachment ? nil : .init(language: "en", startFrame: 0,
                    narrator: .init(kind: "recording", mediaRef: asset.id)))
            Self.relinkAndRestore(asset)
            let before = harness.editor.editPlans
            let timeline = harness.editor.timeline
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            #expect(throws: EditPlanValidationError.self) {
                try harness.editor.changeEditPlans(updates: [prepared.plan], actionName: "Attach", narrationValidation: prepared.validation)
            }
            #expect(harness.editor.editPlans == before)
            #expect(harness.editor.timeline == timeline)
            #expect(!undo.canUndo)
        }
    }

    private static func relinkAndRestore(_ asset: MediaAsset) {
        let context = asset.preparationContext
        let identity = asset.inputIdentity
        asset.url = asset.url.appendingPathExtension("relinked")
        asset.url = context.sourceURL
        asset.inputIdentity = identity
        #expect(asset.url == context.sourceURL)
        #expect(asset.inputIdentity == identity)
        #expect(asset.preparationContext != context)
    }

    private func withRecording(_ operation: @MainActor (ToolHarness, MediaAsset) async throws -> Void) async throws {
        let directory = try await PlanNarrationFixtures.makeAudio()
        do {
            let harness = ToolHarness()
            let asset = harness.addAsset(id: "recording", type: .audio, duration: 3)
            asset.url = directory.appendingPathComponent("voice.wav")
            try await asset.prepareInputIdentity()
            harness.editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
            let plan = EditPlan(name: "Recording", timelineId: harness.editor.activeTimelineId,
                fps: harness.editor.timeline.fps, width: harness.editor.timeline.width, height: harness.editor.timeline.height,
                scriptBeats: PlanNarrationFixtures.beats())
            try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
            try await harness.editor.setPlanNarrationIntent(planId: plan.id,
                request: .init(language: "en", startFrame: 0, narrator: .init(kind: "recording", mediaRef: asset.id)))
            try await operation(harness, asset)
        } catch {
            try await PlanNarrationFixtures.remove(directory)
            throw error
        }
        try await PlanNarrationFixtures.remove(directory)
    }

    @concurrent private static func changeBytes(_ url: URL) async throws { try Data("different recording".utf8).write(to: url) }
}
