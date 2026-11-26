import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

struct AudioFinishingRenderTests {
    @Test(arguments: [false, true])
    func positiveGainSurvivesEncodedOutput(nested: Bool) async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        do {
            let source = directory.appendingPathComponent("tone.wav")
            var clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
            clip.effects = [Effect(type: Clip.loudnessEffectType, enabled: true, params: ["gainDB": EffectParam(value: 6)])]
            let child = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
            var carrier = Fixtures.clip(mediaRef: child.id, mediaType: .audio, start: 0, duration: 60)
            carrier.sourceClipType = .sequence
            let timeline = nested ? Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [carrier])]) : child
            let built = try await CompositionBuilder.build(
                timeline: timeline, resolveURL: { $0 == "tone" ? source : nil },
                resolveTimeline: { $0 == child.id ? child : nil }, renderSize: CGSize(width: 320, height: 180)
            )
            let session = try #require(AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A))
            session.audioMix = built.audioMix
            let output = directory.appendingPathComponent("mix.m4a")
            try await session.export(to: output, as: .m4a)
            try AudioGainTap.validate(built.audioMix)
            let before = try await AudioFinishingFixtures.rms(source)
            let after = try await AudioFinishingFixtures.rms(output)
            #expect(abs(20 * log10(after / before) - 6) < 0.25)
        } catch {
            try await AudioFinishingFixtures.remove(directory)
            throw error
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func detectedSecondsMapThroughTrimAndSpeed() {
        let clip = Fixtures.clip(mediaType: .audio, start: 60, duration: 30, trimStart: 30, speed: 2)
        let dips = CompositionBuilder.gainDips(clip: clip, timescale: 30,
            regions: [.init(start: 1.4, end: 2.2)], depthDB: -24, fadeSeconds: 0.03)
        #expect(dips.count == 1)
        #expect(dips.first?.start == 66)
        #expect(dips.first?.end == 78)
    }

    @Test func attenuationRemainsAudibleAfterVisualRefresh() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        do {
            let source = directory.appendingPathComponent("tone.wav")
            var clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
            clip.effects = [Effect(type: Clip.debreathEffectType, enabled: true, params: ["amount": EffectParam(value: 1)])]
            let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
            let built = try await CompositionBuilder.build(timeline: timeline, resolveURL: { _ in source },
                                                            renderSize: CGSize(width: 320, height: 180))
            let (mix, _) = try await CompositionBuilder.buildVisuals(
                timeline: timeline, trackMappings: built.trackMappings,
                compositionDuration: built.composition.duration, renderSize: CGSize(width: 320, height: 180),
                preparedAudio: PreparedAudio(breaths: ["tone": [.init(start: 0.5, end: 1.5)]])
            )
            let session = try #require(AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A))
            session.audioMix = mix
            let output = directory.appendingPathComponent("dip.m4a")
            try await session.export(to: output, as: .m4a)
            let dry = try await AudioFinishingFixtures.rms(output, range: 0.1...0.3)
            let dip = try await AudioFinishingFixtures.rms(output, range: 0.8...1.2)
            #expect(20 * log10(dip / dry) < -22)
        } catch {
            try await AudioFinishingFixtures.remove(directory)
            throw error
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func trimmedSourceEventAttenuatesOneSecondIntoClip() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        do {
            let source = directory.appendingPathComponent("tone.wav")
            var clip = Fixtures.clip(mediaRef: "tone", mediaType: .audio, start: 0, duration: 90, trimStart: 30)
            clip.effects = [Effect(type: Clip.debreathEffectType, enabled: true, params: ["amount": EffectParam(value: 1)])]
            let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
            let built = try await CompositionBuilder.build(timeline: timeline, resolveURL: { _ in source },
                                                            renderSize: CGSize(width: 320, height: 180))
            let (mix, _) = try await CompositionBuilder.buildVisuals(
                timeline: timeline, trackMappings: built.trackMappings,
                compositionDuration: built.composition.duration, renderSize: CGSize(width: 320, height: 180),
                preparedAudio: PreparedAudio(breaths: ["tone": [.init(start: 2.0, end: 3.0)]])
            )
            let session = try #require(AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A))
            session.audioMix = mix
            let output = directory.appendingPathComponent("trimmed_dip.m4a")
            try await session.export(to: output, as: .m4a)
            let dry = try await AudioFinishingFixtures.rms(output, range: 0.2...0.8)
            let dip = try await AudioFinishingFixtures.rms(output, range: 1.2...1.8)
            #expect(20 * log10(dip / dry) < -20)
        } catch {
            try await AudioFinishingFixtures.remove(directory)
            throw error
        }
        try await AudioFinishingFixtures.remove(directory)
    }
}
