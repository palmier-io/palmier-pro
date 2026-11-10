import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@MainActor
struct AudioFinishingMutationTests {
    enum Interruption: CaseIterable, Sendable { case cancel, edit, replaceSource, close, unmeasurable }

    @Test(arguments: Interruption.allCases)
    func interruptedFinishingPreservesStateAndUndo(interruption: Interruption) async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "voice", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]
        let manager = UndoManager()
        editor.undo.attach(manager)
        let entered = AsyncSemaphore(value: 0)
        let resume = AsyncSemaphore(value: 0)
        let task = Task {
            try await editor.matchLoudness(clipIds: [clip.id], targetLUFS: -16, actionName: "Match") { _, _, _ in
                Self.verifyBackgroundExecution()
                await entered.signal()
                try await resume.wait()
                return LoudnessMeasurement(
                    status: interruption == .unmeasurable ? .belowGate : .measured,
                    integratedLUFS: interruption == .unmeasurable ? nil : -25,
                    truePeakDBFS: nil,
                    analyzedFrames: 96_000,
                    sampleRate: 48_000
                )
            }
        }
        try await entered.wait()
        switch interruption {
        case .cancel: task.cancel()
        case .edit: editor.timeline.tracks[0].clips[0].volume = 0.5
        case .replaceSource: try await touch(source)
        case .close: await editor.projectPackageCoordinator.beginClosing()
        case .unmeasurable: break
        }
        let expected = editor.timeline
        await resume.signal()
        do {
            _ = try await task.value
            Issue.record("Interrupted finishing committed")
        } catch {
            #expect(editor.timeline == expected)
            #expect(editor.loudnessInFlight.isEmpty)
            #expect(!manager.canUndo)
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    private nonisolated static func verifyBackgroundExecution() {
        #expect(!Thread.isMainThread)
    }

    @concurrent
    private func touch(_ url: URL) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as! Date).addingTimeInterval(2)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
