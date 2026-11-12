import Foundation
import Testing
@testable import CompositorPro

@Suite("Dialogue-first measured mixing")
@MainActor
struct DialogueMixTests {
    @Test func stagesDucksMeasuresPersistsAndUndoesOneMix() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let manager = UndoManager()
        editor.undo.attach(manager)
        let before = editor.timeline
        let receipt = try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        #expect(receipt.changed)
        #expect(receipt.state.request.target.accepts(receipt.state.measurement))
        #expect(receipt.state.speechBalance.passes)
        #expect(receipt.state.speechBalance.windows.first?.marginDB ?? 0 >= 6)
        let mixed = editor.timeline
        #expect(mixed.tracks[0].clips[0].startFrame == before.tracks[0].clips[0].startFrame)
        #expect(mixed.tracks[0].clips[0].durationFrames == before.tracks[0].clips[0].durationFrames)
        #expect(mixed.tracks[1].clips[0].volumeTrack?.sample(at: 40, fallback: 0) == -12)
        #expect(mixed.tracks[1].clips[0].fadeInFrames == 6)
        #expect(mixed.tracks[2].clips[0].volumeTrack == nil)
        #expect(try await DialogueMixFixtures.persisted(mixed, directory: directory) == mixed)
        let independentlyMeasured = try await AudioMixAnalyzer.measure(timeline: mixed, timelines: [], urls: editor.mediaResolver.expectedURLMap())
        #expect(receipt.state.request.target.accepts(independentlyMeasured))
        let repeated = try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        #expect(!repeated.changed)
        #expect(editor.timeline == mixed)
        manager.undo()
        #expect(editor.timeline == before)
        #expect(!manager.canUndo)
        manager.redo()
        #expect(editor.timeline == mixed)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func protectsManualAutomationAndReclaimsOnlyUnchangedOwnedEnvelopes() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let manual = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: -3.0), Keyframe(frame: 90, value: -3.0)])
        editor.timeline.tracks[1].clips[0].volumeTrack = manual
        let before = editor.timeline
        let manager = UndoManager()
        editor.undo.attach(manager)
        await #expect(throws: AudioMixError.self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        }
        #expect(editor.timeline == before)
        #expect(!manager.canUndo)
        _ = try await editor.mixAudio(request: DialogueMixFixtures.request, replaceAutomation: true, finish: DialogueMixFixtures.finish)
        var revised = DialogueMixFixtures.request
        revised.ducking.duckDb = -9
        _ = try await editor.mixAudio(request: revised, finish: DialogueMixFixtures.finish)
        #expect(editor.timeline.tracks[1].clips[0].volumeTrack?.sample(at: 40, fallback: 0) == -9)
        editor.timeline.tracks[1].clips[0].volumeTrack?.keyframes[0].value = -2
        let userEdited = editor.timeline
        await #expect(throws: AudioMixError.self) { try await editor.mixAudio(request: revised, finish: DialogueMixFixtures.finish) }
        #expect(editor.timeline == userEdited)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func voiceAutomationAndProcessingRemainIntact() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let envelope = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: -2.0), Keyframe(frame: 60, value: -2.0)])
        let processing = [Effect(type: Clip.loudnessEffectType, enabled: true, params: ["gainDB": .init(value: 3)])]
        editor.timeline.tracks[0].clips[0].volumeTrack = envelope
        editor.timeline.tracks[0].clips[0].effects = processing
        _ = try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        #expect(editor.timeline.tracks[0].clips[0].volumeTrack == envelope)
        #expect(editor.timeline.tracks[0].clips[0].effects == processing)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func shortEffectsUseSamplePeaksInsteadOfInventedLoudness() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let effect = Fixtures.clip(id: "effect", mediaRef: "effect-source", mediaType: .audio, start: 80, duration: 6)
        editor.timeline.tracks.append(Fixtures.audioTrack(clips: [effect]))
        DialogueMixFixtures.addAsset(id: effect.mediaRef, name: "Accent", source: directory.appendingPathComponent("tone.wav"), to: editor)
        var request = DialogueMixFixtures.request
        request.roles.append(.init(clipId: "effect", role: .effects, peakDBFS: -18))
        let result = try await editor.mixAudio(request: request, finish: DialogueMixFixtures.finish)
        #expect(result.state.request.target.accepts(result.state.measurement))
        #expect(editor.clipFor(id: effect.id)?.volumeTrack == nil)
        #expect(result.state.warnings.isEmpty)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func impossibleSummedHeadroomRefusesWithoutMutation() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let before = editor.timeline
        let manager = UndoManager()
        editor.undo.attach(manager)
        await #expect(throws: AudioFinishingError.self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: { input, request, replace in
                try await AudioMixFinisher.finish(input, request: request, replaceAutomation: replace, measure: { _, _, _, range in
                    .init(loudness: .init(status: .measured, integratedLUFS: range == nil ? -30 : -24,
                                         truePeakDBFS: range == nil ? 0 : -12, analyzedFrames: 144_000, sampleRate: 48_000),
                          samplePeakDBFS: -12, clippedSamples: 0)
                }, speech: DialogueMixFixtures.speech)
            })
        }
        #expect(editor.timeline == before)
        #expect(!manager.canUndo)
        try await AudioFinishingFixtures.remove(directory)
    }

    enum Interruption: CaseIterable, Sendable { case cancel, editVoice, replaceURL, switchTimeline, saveAs, close }

    @Test(arguments: Interruption.allCases)
    func interruptedPreparationCannotCommit(interruption: Interruption) async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let entered = AsyncSemaphore(value: 0)
        let resume = AsyncSemaphore(value: 0)
        let manager = UndoManager()
        editor.undo.attach(manager)
        let task = Task {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: { input, request, replace in
                await entered.signal()
                try await resume.wait()
                return try await DialogueMixFixtures.finish(input, request, replace)
            })
        }
        try await entered.wait()
        switch interruption {
        case .cancel: task.cancel()
        case .editVoice: editor.timeline.tracks[0].clips[0].trimStartFrame += 1
        case .replaceURL: editor.mediaAssetsById["voice-source"]?.url = directory.appendingPathComponent("replacement.wav")
        case .switchTimeline:
            let other = Fixtures.timeline()
            editor.timelines.append(other)
            editor.activeTimelineId = other.id
        case .saveAs: editor.projectURL = directory.appendingPathComponent("saved-as.compositorpro")
        case .close: _ = editor.projectPackageCoordinator.beginClosing()
        }
        let expected = editor.timelines
        await resume.signal()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(editor.timelines == expected)
        #expect(!manager.canUndo)
        #expect(editor.audioMixOperation?.id == nil)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func wholeClipSpeechApproximationCannotCertifyMixing() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let before = editor.timeline
        await #expect(throws: AudioFinishingError.self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: { input, request, replace in
                try await AudioMixFinisher.finish(input, request: request, replaceAutomation: replace, speech: { sources, _ in
                    .init(timings: sources.map { .init(clipId: $0.clip.id, ranges: [$0.clip.startFrame..<$0.clip.endFrame], method: .wholeClip) },
                          sourceVersions: [:])
                })
            })
        }
        #expect(editor.timeline == before)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func splitAmbienceKeepsSeamUnfadedAndSharesOneGain() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let original = editor.timeline.tracks[2].clips[0]
        let split = try #require(EditorViewModel.splitValues(of: original, atFrame: 45))
        editor.timeline.tracks[2].clips = [split.left, split.right]
        var request = DialogueMixFixtures.request
        request.roles.append(.init(clipId: split.right.id, role: .ambience))
        _ = try await editor.mixAudio(request: request, finish: DialogueMixFixtures.finish)
        let left = try #require(editor.clipFor(id: split.left.id))
        let right = try #require(editor.clipFor(id: split.right.id))
        #expect(left.fadeOutFrames == 0)
        #expect(right.fadeInFrames == 0)
        #expect(left.fadeInFrames == 6)
        #expect(right.fadeOutFrames == 6)
        #expect(left.volume == right.volume)
        #expect(left.trimStartFrame == split.left.trimStartFrame)
        #expect(right.trimStartFrame == split.right.trimStartFrame)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func aLoudBedCannotPassOnlyBecauseDeliveryLoudnessPasses() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let before = editor.timeline
        var request = DialogueMixFixtures.request
        request.roles[1].targetLUFS = -12
        request.ducking.duckDb = 0
        await #expect(throws: AudioFinishingError.self) {
            try await editor.mixAudio(request: request, finish: DialogueMixFixtures.finish)
        }
        #expect(editor.timeline == before)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func voiceOnlyMixMeasuresSilenceInBackgroundStem() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        editor.timeline.tracks.removeLast(2)
        var request = DialogueMixFixtures.request
        request.roles = [request.roles[0]]
        let receipt = try await editor.mixAudio(request: request, finish: DialogueMixFixtures.finish)
        #expect(receipt.state.speechBalance.passes)
        #expect(receipt.state.speechBalance.windows.first?.backgroundRMSDBFS == nil)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func unsupportedProcessingCannotBeCertifiedAsDryAudio() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        editor.timeline.tracks[0].clips[0].effects = [Effect(type: "audio.unsupported", enabled: true)]
        let before = editor.timeline
        await #expect(throws: AudioFinishingError.self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        }
        #expect(editor.timeline == before)
        try await AudioFinishingFixtures.remove(directory)
    }
}
