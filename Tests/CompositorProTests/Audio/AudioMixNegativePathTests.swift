import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("Measured mixing negative paths")
@MainActor
struct AudioMixNegativePathTests {
    @Test func aSourceChangedDuringMeasurementRefusesTheMix() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let before = editor.timeline
        let manager = UndoManager()
        editor.undo.attach(manager)
        await #expect(throws: (any Error).self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: { input, request, replace in
                try await AudioMixFinisher.finish(input, request: request, replaceAutomation: replace,
                                                 measure: { timeline, timelines, urls, range in
                                                     let measurement = try await AudioMixAnalyzer.measure(
                                                        timeline: timeline, timelines: timelines, urls: urls, range: range)
                                                     // The source bytes change while the mix measures them.
                                                     try Data("changed".utf8).write(to: urls.values.first!)
                                                     return measurement
                                                 },
                                                 speech: DialogueMixFixtures.speech)
            })
        }
        #expect(editor.timeline == before)
        #expect(!manager.canUndo)
    }

    @Test func aStaleSpeechTimingRefusesTheMix() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let before = editor.timeline
        let manager = UndoManager()
        editor.undo.attach(manager)
        await #expect(throws: (any Error).self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: { input, request, replace in
                try await AudioMixFinisher.finish(input, request: request, replaceAutomation: replace,
                                                 speech: { sources, _ in
                                                     .init(timings: sources.map {
                                                         .init(clipId: $0.clip.id, ranges: [0..<5], method: .transcript)
                                                     }, sourceVersions: [:])
                                                 })
            })
        }
        #expect(editor.timeline == before)
        #expect(!manager.canUndo)
    }

    @Test func aMutedClipCannotBeMixedAndIsReported() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        editor.timeline.tracks[0].clips[0].volume = 0
        let before = editor.timeline
        await #expect(throws: (any Error).self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        }
        #expect(editor.timeline == before)
    }

    @Test func anUnassignedAudioClipIsRefused() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let before = editor.timeline
        var request = DialogueMixFixtures.request
        request.roles.removeAll { $0.clipId == "room" }
        await #expect(throws: (any Error).self) {
            try await editor.mixAudio(request: request, finish: DialogueMixFixtures.finish)
        }
        #expect(editor.timeline == before)
    }

    @Test func anUnsupportedChannelLayoutIsRefused() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let url = directory.appendingPathComponent("surround.wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                       AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0.1 }
        }
        try file.write(from: buffer)
        let editor = DialogueMixFixtures.editor(source: url)
        let before = editor.timeline
        await #expect(throws: (any Error).self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        }
        #expect(editor.timeline == before)
    }

    @Test func anUnfinishedEnhancementJobPreventsTheMix() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let before = editor.timeline
        let job = EditorViewModel.EnhancementJob(
            id: UUID(), clipIds: ["voice"], mediaRefs: ["voice-source"], type: .denoise,
            params: .denoise(amount: 0.5), sourceVersions: [:], startedAt: Date(),
            completedAt: nil, status: .running, stage: .analyzing, errors: [], warnings: [],
            changedClipIds: [], timelineId: editor.timeline.id, timelineRevision: 0)
        editor.enhancementJobs[job.id] = job
        await #expect(throws: (any Error).self) {
            try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish)
        }
        #expect(editor.timeline == before)
    }

    @Test func concurrentIdenticalMixesShareOneResult() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        let manager = UndoManager()
        manager.groupsByEvent = false
        editor.undo.attach(manager)
        let first = Task { try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish) }
        let second = Task { try await editor.mixAudio(request: DialogueMixFixtures.request, finish: DialogueMixFixtures.finish) }
        let results = try await [first.value, second.value]
        #expect(results.filter(\.changed).count == 1)
        #expect(results.filter { !$0.changed }.count == 1)
        #expect(editor.timeline.audioMix != nil)
        manager.undo()
        #expect(editor.timeline.audioMix == nil)
        #expect(!manager.canUndo)
    }
}
