import Foundation
import Testing
@testable import CompositorPro

@Suite("Ducking mutation lifecycle")
@MainActor
struct AudioDuckingMutationTests {
    enum Interruption: CaseIterable, Sendable { case cancel, editBed, editVoice, replaceURL, switchTimeline, close }

    private func editor(source: URL) -> EditorViewModel {
        let editor = EditorViewModel()
        let voice = Fixtures.clip(id: "voice", mediaRef: "voice-source", mediaType: .audio,
                                  start: 30, duration: 60, trimStart: 15, speed: 0.5)
        let bed = Fixtures.clip(id: "bed", mediaRef: "bed-source", mediaType: .audio, start: 0, duration: 90)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [voice]), Fixtures.audioTrack(clips: [bed])])
        editor.mediaAssets = [
            MediaAsset(id: voice.mediaRef, url: source, type: .audio, name: "Voice", duration: 3),
            MediaAsset(id: bed.mediaRef, url: source, type: .audio, name: "Bed", duration: 3),
        ]
        return editor
    }

    @Test(arguments: Interruption.allCases)
    func interruptedDetectionCannotWriteAnEnvelope(interruption: Interruption) async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = editor(source: directory.appendingPathComponent("tone.wav"))
        let manager = UndoManager()
        editor.undo.attach(manager)
        let entered = AsyncSemaphore(value: 0)
        let resume = AsyncSemaphore(value: 0)
        let task = Task {
            try await editor.duckAudio(bedId: "bed", sourceIds: ["voice"], resolveSpeech: { sources, _, _ in
                await entered.signal()
                try await resume.wait()
                let versions = try await LoudnessAnalyzer.sourceVersions(for: sources.map(\.url))
                return AudioSpeechTiming.Result(timings: [.init(clipId: "voice", ranges: [30..<60], method: .voiceActivity)],
                                                sourceVersions: versions)
            })
        }
        try await entered.wait()
        switch interruption {
        case .cancel: task.cancel()
        case .editBed: editor.timeline.tracks[1].clips[0].volume = 0.5
        case .editVoice: editor.timeline.tracks[0].clips[0].trimStartFrame += 1
        case .replaceURL: editor.mediaAssetsById["voice-source"]?.url = directory.appendingPathComponent("replaced.wav")
        case .switchTimeline:
            let other = Fixtures.timeline()
            editor.timelines.append(other)
            editor.activeTimelineId = other.id
        case .close: _ = editor.projectPackageCoordinator.beginClosing()
        }
        let expected = editor.timelines
        await resume.signal()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(editor.timelines == expected)
        #expect(!manager.canUndo)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func completedDuckingHasOneUndoAndIdenticalReplacementIsANoOp() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = editor(source: directory.appendingPathComponent("tone.wav"))
        let manager = UndoManager()
        manager.groupsByEvent = false
        editor.undo.attach(manager)
        let before = editor.timeline
        let resolve: @Sendable ([AudioSpeechTiming.Source], Int, Bool) async throws -> AudioSpeechTiming.Result = { sources, _, _ in
            .init(timings: [.init(clipId: "voice", ranges: [30..<60], method: .voiceActivity)],
                  sourceVersions: try await LoudnessAnalyzer.sourceVersions(for: sources.map(\.url)))
        }
        let first = try await editor.duckAudio(bedId: "bed", sourceIds: ["voice"], resolveSpeech: resolve)
        let second = try await editor.duckAudio(bedId: "bed", sourceIds: ["voice"], overwrite: true, resolveSpeech: resolve)
        #expect(first.changed)
        #expect(!second.changed)
        #expect(editor.timeline.tracks[1].clips[0].volumeTrack?.sample(at: 40, fallback: 0) == -12)
        manager.undo()
        #expect(editor.timeline == before)
        #expect(!manager.canUndo)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func zeroDecibelsDoesNotAnalyzeOrCreateUndo() async throws {
        let editor = editor(source: URL(fileURLWithPath: "/not-used.wav"))
        let manager = UndoManager()
        editor.undo.attach(manager)
        let result = try await editor.duckAudio(bedId: "bed", duckDb: 0, resolveSpeech: { _, _, _ in
            Issue.record("A no-op requested speech analysis")
            throw CancellationError()
        })
        #expect(!result.changed)
        #expect(!manager.canUndo)
    }
}
