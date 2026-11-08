import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

enum PlanNarrationFixtures {
    static let fingerprint = String(repeating: "a", count: 64)

    static func beats() -> [ScriptBeat] {
        [.init(beatId: "first-beat", text: "First claim.", purpose: "Introduce the consequence."),
         .init(beatId: "second-beat", text: "Second claim.", purpose: "Explain the mechanism.")]
    }

    static func transcript() -> TranscriptionResult {
        .init(text: "First claim. Second claim.", language: "en", words: [
            .init(text: "First", start: 0.2, end: 0.4), .init(text: "claim.", start: 0.5, end: 0.8),
            .init(text: "Second", start: 1.5, end: 1.8), .init(text: "claim.", start: 2, end: 2.5),
        ], segments: [])
    }

    static func timing(revision: String = "revision") throws -> NarrationTiming {
        try NarrationAlignment.align(beats: beats(), transcript: transcript(), duration: NarrationTime(CMTime(value: 3, timescale: 1)),
                                      revision: revision, fingerprint: fingerprint)
    }

    @concurrent
    static func makeAudio(seconds: Int = 3) async throws -> URL {
        guard (1...60).contains(seconds) else { throw CocoaError(.fileWriteUnknown) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("narration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("voice.wav"), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48_000))!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][index] = Float(0.1 * sin(Double(index) / 10))
            }
            try file.write(from: buffer)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @concurrent
    static func remove(_ directory: URL) async throws { try FileManager.default.removeItem(at: directory) }
}

struct PlanNarrationTests {
    @Test(arguments: ["empty text", "empty purpose", "empty pronunciation", "punctuation only", "duplicate IDs", "empty script"])
    func invalidScriptsAreRefused(failure: String) throws {
        var beats = PlanNarrationFixtures.beats()
        switch failure {
        case "empty text": beats[0].text = " "
        case "empty purpose": beats[0].purpose = " "
        case "empty pronunciation": beats[0].spokenText = " "
        case "punctuation only": beats[0].text = "..."
        case "duplicate IDs": beats[1].beatId = beats[0].beatId
        default: beats = []
        }
        var plan = EditPlan(name: "Invalid script", timelineId: "timeline", fps: 30, width: 1920, height: 1080, scriptBeats: beats)
        #expect(throws: EditPlanValidationError.self) { try plan.validateArtifacts() }
    }

    @Test(arguments: ["missing words", "different words", "missing time", "negative time", "non-finite", "overlap", "past duration"])
    func incompleteOrInvalidAlignmentNeverKeepsPartialAnchors(failure: String) throws {
        let original = PlanNarrationFixtures.transcript()
        var words = original.words
        switch failure {
        case "missing words": words.removeLast()
        case "different words": words[3] = .init(text: "unrelated", start: 2, end: 2.5)
        case "missing time": words[3] = .init(text: "claim.", start: nil, end: nil)
        case "negative time": words[3] = .init(text: "claim.", start: -1, end: 2.5)
        case "non-finite": words[3] = .init(text: "claim.", start: .infinity, end: .infinity)
        case "overlap": words[3] = .init(text: "claim.", start: 1.6, end: 2.5)
        default: words[3] = .init(text: "claim.", start: 2, end: 4)
        }
        let result = try NarrationAlignment.align(beats: PlanNarrationFixtures.beats(),
                                                 transcript: .init(text: original.text, language: nil, words: words, segments: []),
                                                 duration: NarrationTime(CMTime(value: 3, timescale: 1)),
                                                 revision: "revision", fingerprint: PlanNarrationFixtures.fingerprint)
        #expect(result.anchors.isEmpty)
        #expect(result.unresolvedBeatIds == ["first-beat", "second-beat"])
        try result.validated(beats: PlanNarrationFixtures.beats(), revision: "revision")
    }

    @Test func pronunciationWordingMustMatchSpokenWords() throws {
        var beats = PlanNarrationFixtures.beats()
        beats[0].text = "1st claim."
        beats[0].spokenText = "First claim."
        let timing = try NarrationAlignment.align(beats: beats, transcript: PlanNarrationFixtures.transcript(),
                                                 duration: NarrationTime(CMTime(value: 3, timescale: 1)),
                                                 revision: "revision", fingerprint: PlanNarrationFixtures.fingerprint)
        #expect(timing.unresolvedBeatIds.isEmpty)
        #expect(timing.anchors.map(\.beatId) == beats.map(\.beatId))
    }

    @Test(arguments: [(1, 60, 1), (1, 100, 0), (3, 100, 1)])
    func frameRoundingUsesNearestHalfAwayFromZero(value: Int64, timescale: Int32, expected: Int) throws {
        let time = try NarrationTime(CMTime(value: value, timescale: timescale))
        #expect(try time.frame(fps: 30) == expected)
        #expect(try time.frame(fps: 30, rounding: .roundTowardZero) == Int(value * 30 / Int64(timescale)))
    }

    @Test(arguments: ["missing beat", "reversed beats", "short hold", "overflow", "stale revision"])
    func invalidSceneResolutionIsRefused(failure: String) throws {
        var plan = EditPlan(name: "Narration", timelineId: "timeline", fps: 30, width: 1920, height: 1080,
                            scriptBeats: PlanNarrationFixtures.beats(), narration: .init(mediaRef: "audio", startFrame: 30))
        plan.narrationTiming = try PlanNarrationFixtures.timing(revision: #require(plan.narrationRevision))
        var link = SceneNarrationLink(firstBeatId: "first-beat", lastBeatId: "first-beat")
        switch failure {
        case "missing beat": link.firstBeatId = "missing"
        case "reversed beats": link.firstBeatId = "second-beat"
        case "short hold": link.minimumHoldSeconds = 2
        case "overflow": plan.narration?.startFrame = maxFrameArg
        default: plan.narrationRevision = UUID().uuidString
        }
        #expect(throws: EditPlanValidationError.self) { try plan.resolvedNarrationRange(link) }
    }

    @Test func linkedScenesShareOneBoundaryAndAbsorbLeadingSilence() throws {
        var plan = EditPlan(name: "Narration", timelineId: "timeline", fps: 30, width: 1920, height: 1080,
                            scriptBeats: PlanNarrationFixtures.beats(), narration: .init(mediaRef: "audio", startFrame: 30))
        plan.narrationTiming = try PlanNarrationFixtures.timing(revision: #require(plan.narrationRevision))
        #expect(try plan.resolvedNarrationRange(.init(firstBeatId: "first-beat", lastBeatId: "first-beat")) == 30..<75)
        #expect(try plan.resolvedNarrationRange(.init(firstBeatId: "second-beat", lastBeatId: "second-beat")) == 75..<120)
    }

    @Test func scriptClaimReferencesParticipateInReviewBlockingAndDependencyReceipts() throws {
        var ledger = SourceClaimLedgerFixtures.ledger()
        ledger.claims[0].status = .unresolved
        var beats = PlanNarrationFixtures.beats()
        beats[0].claimIds = ["share"]
        var plan = EditPlan(name: "Claims", timelineId: "timeline", fps: 30, width: 1920, height: 1080,
                            sourceLedger: ledger, scriptBeats: beats)
        plan.shots = [.init(id: "linked-scene", title: "Claim", startFrame: 0, endFrame: 30,
                            narrationLink: .init(firstBeatId: "first-beat", lastBeatId: "first-beat"))]
        try plan.validateArtifacts()
        #expect(plan.unresolvedClaimIDs == ["share"])
        #expect(plan.claimDependents(["share"])["beatIds"] == ["first-beat"])
        #expect(plan.claimDependents(["share"])["shotIds"] == ["linked-scene"])
        plan.scriptBeats?[0].claimIds = ["missing"]
        #expect(throws: EditPlanValidationError.self) { try plan.validateArtifacts() }
    }
}

actor NarrationTranscriptGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<TranscriptionResult, Never>?

    func transcript() async -> TranscriptionResult {
        await withCheckedContinuation { continuation in
            completion = continuation
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        completion?.resume(returning: PlanNarrationFixtures.transcript())
        completion = nil
    }
}

@Suite("Narration preparation lifecycle")
@MainActor
struct PlanNarrationLifecycleTests {
    @Test func replacementNarrationRecomputesChangedPronunciationTiming() async throws {
        let originalDirectory = try await PlanNarrationFixtures.makeAudio()
        let replacementDirectory: URL
        do { replacementDirectory = try await PlanNarrationFixtures.makeAudio(seconds: 4) }
        catch {
            try await PlanNarrationFixtures.remove(originalDirectory)
            throw error
        }
        do {
            let originalURL = originalDirectory.appendingPathComponent("voice.wav")
            let replacementURL = replacementDirectory.appendingPathComponent("voice.wav")
            let service = NarrationTimingService { url, _ in
                if url == originalURL { return PlanNarrationFixtures.transcript() }
                return .init(text: "Different pronunciation. Second claim.", language: "en", words: [
                    .init(text: "Different", start: 0.2, end: 0.6), .init(text: "pronunciation.", start: 0.7, end: 1.8),
                    .init(text: "Second", start: 2.5, end: 2.8), .init(text: "claim.", start: 3, end: 3.5),
                ], segments: [])
            }
            let harness = ToolHarness()
            let audio = harness.addAsset(id: "narration-audio", type: .audio, duration: 3)
            audio.url = originalURL
            let plan = EditPlan(id: "narration-plan", name: "Narration", timelineId: harness.editor.activeTimelineId,
                                fps: 30, width: 1920, height: 1080, scriptBeats: PlanNarrationFixtures.beats(),
                                narration: .init(mediaRef: audio.id, startFrame: 0))
            try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
            let executor = ToolExecutor(editor: harness.editor, narrationTimingService: service)
            #expect(!(await executor.execute(name: "plan_edit", args: ["action": "measure_narration", "planId": plan.id])).isError)
            var revised = try #require(harness.editor.editPlan(id: plan.id))
            let oldTiming = try #require(revised.narrationTiming)
            revised.scriptBeats?[0].spokenText = "Different pronunciation."
            try harness.editor.changeEditPlans(updates: [revised], actionName: "Revise")
            audio.url = replacementURL
            audio.duration = 4
            #expect(!(await executor.execute(name: "plan_edit", args: ["action": "measure_narration", "planId": plan.id])).isError)
            let measured = try #require(harness.editor.editPlan(id: plan.id))
            #expect(measured.narrationTiming?.duration.cmTime.seconds == 4)
            #expect(measured.narrationTiming?.sourceFingerprint != oldTiming.sourceFingerprint)
            #expect(try measured.resolvedNarrationRange(.init(firstBeatId: "first-beat", lastBeatId: "first-beat")) == 0..<75)
            #expect(try measured.resolvedNarrationRange(.init(firstBeatId: "second-beat", lastBeatId: "second-beat")) == 75..<120)
        } catch {
            try await PlanNarrationFixtures.remove(originalDirectory)
            try await PlanNarrationFixtures.remove(replacementDirectory)
            throw error
        }
        try await PlanNarrationFixtures.remove(originalDirectory)
        try await PlanNarrationFixtures.remove(replacementDirectory)
    }

    @Test(arguments: ["cancel", "script", "timeline", "asset", "file", "failure"])
    func canceledFailedOrStalePreparationCannotCommit(change: String) async throws {
        let directory = try await PlanNarrationFixtures.makeAudio()
        do {
            let harness = ToolHarness()
            let audio = harness.addAsset(id: "narration-audio", type: .audio, duration: 3)
            audio.url = directory.appendingPathComponent("voice.wav")
            let plan = EditPlan(id: "narration-plan", name: "Narration", timelineId: harness.editor.activeTimelineId,
                                fps: harness.editor.timeline.fps, width: harness.editor.timeline.width, height: harness.editor.timeline.height,
                                scriptBeats: PlanNarrationFixtures.beats(), narration: .init(mediaRef: audio.id, startFrame: 0))
            try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
            let gate = NarrationTranscriptGate()
            let service = NarrationTimingService { _, _ in
                let result = await gate.transcript()
                if change == "failure" { throw CocoaError(.fileReadCorruptFile) }
                return result
            }
            let executor = ToolExecutor(editor: harness.editor, narrationTimingService: service)
            let operation = Task { await executor.execute(name: "plan_edit", args: ["action": "measure_narration", "planId": plan.id]) }
            await gate.waitUntilStarted()
            switch change {
            case "cancel": operation.cancel()
            case "script":
                var revised = try #require(harness.editor.editPlan(id: plan.id))
                revised.scriptBeats?[0].spokenText = "Changed pronunciation."
                try harness.editor.changeEditPlans(updates: [revised], actionName: "Revise")
            case "timeline": harness.editor.timeline.width = 1280
            case "asset": audio.url = directory.appendingPathComponent("replacement.wav")
            case "file":
                let url = audio.url
                try await Task.detached { try Data("changed file".utf8).write(to: url) }.value
            default: break
            }
            let before = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            await gate.finish()
            #expect(await operation.value.isError)
            #expect(harness.editor.editPlans == before)
            #expect(!undo.canUndo)
            #expect(harness.editor.editPlan(id: plan.id)?.narrationTiming == nil)
        } catch {
            try await PlanNarrationFixtures.remove(directory)
            throw error
        }
        try await PlanNarrationFixtures.remove(directory)
    }
}
