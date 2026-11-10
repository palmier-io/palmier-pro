import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("Mixed PCM measurement")
struct AudioMixAnalyzerTests {
    @Test func summedTracksAreMeasuredAfterGainProcessing() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        let single = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        let summed = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip]), Fixtures.audioTrack(clips: [clip])])
        var gained = single
        gained.tracks[0].clips[0].effects = [Effect(type: Clip.loudnessEffectType, enabled: true,
                                                params: ["gainDB": EffectParam(value: 6.0206)])]
        let dry = try await AudioMixAnalyzer.measure(timeline: single, timelines: [], urls: ["tone": source])
        let mix = try await AudioMixAnalyzer.measure(timeline: summed, timelines: [], urls: ["tone": source])
        let tap = try await AudioMixAnalyzer.measure(timeline: gained, timelines: [], urls: ["tone": source])
        #expect(abs(try #require(mix.samplePeakDBFS) - #require(dry.samplePeakDBFS) - 6.0206) < 0.05)
        #expect(abs(try #require(tap.loudness.integratedLUFS) - #require(dry.loudness.integratedLUFS) - 6.0206) < 0.05)
        #expect(abs(try #require(tap.samplePeakDBFS) - #require(mix.samplePeakDBFS)) < 0.05)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func trimmedSpeedChangeUsesSelectedSourceAudio() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("levels.wav")
        try await AudioFinishingFixtures.writeTone(to: source, amplitudes: [0.02, 0.15, 0.05])
        let clip = Fixtures.clip(mediaRef: "levels", mediaType: .audio, start: 0, duration: 30, trimStart: 30, speed: 2)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        let loud = try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: ["levels": source], range: 3..<12)
        let quiet = try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: ["levels": source], range: 18..<27)
        #expect(abs(try #require(loud.samplePeakDBFS) - #require(quiet.samplePeakDBFS) - 20 * log10(3)) < 0.1)
        #expect(abs(loud.loudness.durationSeconds - 0.3) < 1 / 48_000)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func nestedCarrierEnvelopeMatchesFlatAudio() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        let child = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        var carrier = Fixtures.clip(mediaRef: child.id, mediaType: .audio, start: 0, duration: 60, volume: 0.5)
        carrier.sourceClipType = .sequence
        carrier.volumeTrack = .init(keyframes: [.init(frame: 0, value: -6), .init(frame: 60, value: -6)])
        let nested = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [carrier])])
        var flat = child
        flat.tracks[0].clips[0].volume = 0.5
        flat.tracks[0].clips[0].volumeTrack = carrier.volumeTrack
        let a = try await AudioMixAnalyzer.measure(timeline: nested, timelines: [child], urls: ["tone": source])
        let b = try await AudioMixAnalyzer.measure(timeline: flat, timelines: [], urls: ["tone": source])
        #expect(abs(try #require(a.loudness.integratedLUFS) - #require(b.loudness.integratedLUFS)) < 0.05)
        #expect(a.loudness.analyzedFrames == b.loudness.analyzedFrames)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func leadingAndTrailingSilenceCoverFullTimelineDuration() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let audio = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 30, duration: 30)
        let title = Fixtures.clip(mediaType: .text, start: 0, duration: 90)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [title]), Fixtures.audioTrack(clips: [audio])])
        let built = try await CompositionBuilder.buildAudio(timeline: timeline, resolveURL: { _ in source })
        let duration = try await built.composition.load(.duration)
        var count = 0
        try await AudioTrackReader.readMix(from: built.composition, audioMix: built.audioMix,
                                          timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 90, timescale: 30)),
                                          contentRanges: built.audioContentRanges) {
            count += Int($0.frameLength)
        }
        #expect(count == 144_000, "composition=\(duration.seconds)s decoded=\(count) frames")
        let measurement = try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: ["tone": source])
        #expect(measurement.loudness.analyzedFrames == 144_000)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func measurementMatchesEncodedPlaybackProcessing() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        var clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        clip.effects = [Effect(type: Clip.loudnessEffectType, enabled: true, params: ["gainDB": EffectParam(value: 9)])]
        clip.fadeInFrames = 6
        clip.fadeOutFrames = 6
        clip.volumeTrack = .init(keyframes: [.init(frame: 0, value: -3), .init(frame: 60, value: -3)])
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        let measured = try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: ["tone": source])
        let built = try await CompositionBuilder.build(timeline: timeline, resolveURL: { _ in source },
                                                      renderSize: CGSize(width: 320, height: 180))
        let session = try #require(AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A))
        session.audioMix = built.audioMix
        let output = directory.appendingPathComponent("parity.m4a")
        try await session.export(to: output, as: .m4a)
        let encoded = try await LoudnessAnalyzer.integratedLoudness(for: output, mediaRef: "encoded", cacheDirectory: directory)
        let measuredLUFS = try #require(measured.loudness.integratedLUFS)
        let encodedLUFS = try #require(encoded.integratedLUFS)
        #expect(abs(measuredLUFS - encodedLUFS) < 0.25, "PCM=\(measuredLUFS) LUFS, export=\(encodedLUFS) LUFS")
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func insufficientSourceDurationCannotPassMeasurement() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 120)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        await #expect(throws: (any Error).self) {
            try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: ["tone": source])
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test(arguments: [0..<30, 60..<90])
    func silenceOnlyRangesRemainBelowGate(range: Range<Int>) async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 30, duration: 30)
        let title = Fixtures.clip(mediaType: .text, start: 0, duration: 90)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [title]), Fixtures.audioTrack(clips: [clip])])
        let result = try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [],
                                                      urls: ["tone": directory.appendingPathComponent("tone.wav")], range: range)
        #expect(result.loudness.status == .belowGate)
        #expect(result.loudness.analyzedFrames == 48_000)
        #expect(result.samplePeakDBFS == nil)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func shortDecodeWithoutIntentionalSilenceCannotPass() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let asset = AVURLAsset(url: directory.appendingPathComponent("tone.wav"))
        await #expect(throws: (any Error).self) {
            try await AudioTrackReader.readMix(from: asset, audioMix: AVMutableAudioMix(),
                                              timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 4, timescale: 1))) { _ in }
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func cancellationDuringDecodingReleasesMixGate() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let asset = AVURLAsset(url: directory.appendingPathComponent("tone.wav"))
        let task = Task {
            try await AudioTrackReader.readMix(from: asset, audioMix: AVMutableAudioMix(),
                                              timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1))) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        let result = try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [],
                                                      urls: ["tone": directory.appendingPathComponent("tone.wav")])
        #expect(result.loudness.status == .measured)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func missingNestedTimelineCannotBecomePassingSilence() async throws {
        var carrier = Fixtures.clip(mediaRef: "missing-child", mediaType: .audio, start: 0, duration: 30)
        carrier.sourceClipType = .sequence
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [carrier])])
        await #expect(throws: (any Error).self) {
            try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: [:])
        }
    }

    @Test func cancellationBeforeMeasurementDoesNotHoldDecodeGate() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: ["tone": source])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let result = try await AudioMixAnalyzer.measure(timeline: timeline, timelines: [], urls: ["tone": source])
        #expect(result.loudness.status == .measured)
        try await AudioFinishingFixtures.remove(directory)
    }
}
