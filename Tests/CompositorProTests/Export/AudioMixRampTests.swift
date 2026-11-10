import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

/// AVFoundation raises an Objective-C exception Swift cannot catch when two volume ramps on one
/// `AVAudioMixInputParameters` overlap, and that exception terminates the process. The only
/// property that keeps the app alive is that the planned ranges are contiguous and disjoint,
/// so that is what these assert — against the real planner, not a copy of it.
@Suite("Audio mix ramp planning")
struct AudioMixRampTests {
    private func overlaps(_ ramps: [CompositionBuilder.PlannedRamp]) -> [String] {
        let sorted = ramps.sorted { CMTimeGetSeconds($0.range.start) < CMTimeGetSeconds($1.range.start) }
        var found: [String] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let aEnd = CMTimeGetSeconds(a.range.end), bStart = CMTimeGetSeconds(b.range.start)
            if aEnd > bStart {
                found.append("\(CMTimeGetSeconds(a.range.start))–\(aEnd) overlaps \(bStart)")
            }
        }
        return found
    }

    private func clipWithBreathers(_ count: Int) -> Clip {
        var clip = Clip(id: "c1", mediaRef: "m1", startFrame: 0, durationFrames: 300)
        clip.volume = 1
        return clip
    }

    /// A dip covering the whole clip, which under the old layered emitter overlapped the
    /// envelope's own whole-clip ramp and killed the app on the first breath.
    @Test func aWholeClipDipDoesNotOverlapTheEnvelope() {
        let timescale: CMTimeScale = 600
        let clip = clipWithBreathers(1)
        let dip = CompositionBuilder.AudioGainDip(
            start: 0, fadeInEnd: 0, fadeOutStart: 300, end: 300, gain: 0.5
        )
        let ramps = CompositionBuilder.planVolumeRamps(
            clip: clip, timescale: timescale, gain: 1, dips: [dip]
        )
        #expect(!ramps.isEmpty)
        #expect(overlaps(ramps).isEmpty)
    }

    @Test func severalDipsOnOneClipNeverOverlap() {
        let timescale: CMTimeScale = 600
        let clip = clipWithBreathers(3)
        let dips = [
            CompositionBuilder.AudioGainDip(start: 0, fadeInEnd: 5, fadeOutStart: 40, end: 45, gain: 0.5),
            CompositionBuilder.AudioGainDip(start: 30, fadeInEnd: 35, fadeOutStart: 80, end: 85, gain: 0.6),
            CompositionBuilder.AudioGainDip(start: 200, fadeInEnd: 205, fadeOutStart: 260, end: 265, gain: 0.4),
        ]
        let ramps = CompositionBuilder.planVolumeRamps(
            clip: clip, timescale: timescale, gain: 0.8, dips: dips
        )
        #expect(overlaps(ramps).isEmpty)
    }

    @Test func aPlainClipStillPlansOneContiguousRun() {
        let timescale: CMTimeScale = 600
        let ramps = CompositionBuilder.planVolumeRamps(
            clip: clipWithBreathers(0), timescale: timescale, gain: 1
        )
        #expect(!ramps.isEmpty)
        #expect(overlaps(ramps).isEmpty)
        let sorted = ramps.sorted { CMTimeGetSeconds($0.range.start) < CMTimeGetSeconds($1.range.start) }
        #expect(CMTimeGetSeconds(sorted.first!.range.start) == 0)
    }

    /// A dip must actually attenuate: the planned volume inside it is lower than outside, so
    /// folding the dips into the envelope did not silently drop the feature.
    @Test func dipsAttenuateThePlannedVolume() {
        let timescale: CMTimeScale = 600
        let clip = clipWithBreathers(1)
        let dip = CompositionBuilder.AudioGainDip(
            start: 100, fadeInEnd: 110, fadeOutStart: 190, end: 200, gain: 0.5
        )
        let ramps = CompositionBuilder.planVolumeRamps(clip: clip, timescale: timescale, dips: [dip])
        #expect(overlaps(ramps).isEmpty)
        let volumeAt: (Double) -> Float = { seconds in
            let t = CMTime(seconds: seconds, preferredTimescale: timescale)
            return ramps.first { CMTimeGetSeconds($0.range.start) <= CMTimeGetSeconds(t)
                && CMTimeGetSeconds($0.range.end) >= CMTimeGetSeconds(t) }?.from ?? -1
        }
        let inside = volumeAt(0.25)
        let outside = volumeAt(0.05)
        #expect(inside >= 0)
        #expect(outside >= 0)
        #expect(inside < outside)
    }

    @Test func plannedVolumesReflectRequestedGain() {
        let timescale: CMTimeScale = 600
        var clip = clipWithBreathers(1)
        clip.volume = 1
        let ramps = CompositionBuilder.planVolumeRamps(clip: clip, timescale: timescale, gain: 1.9)
        #expect(ramps.allSatisfy { $0.from >= 0 })
        #expect(ramps.allSatisfy { $0.to >= 0 })
        #expect(ramps.allSatisfy { $0.from <= 1.9 && $0.to <= 1.9 })
        #expect(ramps.contains { $0.from > 1 || $0.to > 1 })
    }

    @Test(arguments: [(0.8, 1.2, 90, 96), (2.8, 3.2, 144, 150), (1.0, 3.0, 90, 150)])
    func regionsCrossingTrimBoundariesAreClipped(region: (Double, Double, Int, Int)) {
        let clip = Clip(mediaRef: "voice", mediaType: .audio, startFrame: 90,
                        durationFrames: 60, trimStartFrame: 30)
        let dips = CompositionBuilder.gainDips(
            clip: clip, timescale: 30, regions: [.init(start: region.0, end: region.1)],
            depthDB: -12, fadeSeconds: 0.03)
        #expect(dips.count == 1)
        #expect(dips.first?.start == region.2)
        #expect(dips.first?.end == region.3)
        let ramps = CompositionBuilder.planVolumeRamps(clip: clip, timescale: 30, dips: dips)
        #expect(overlaps(ramps).isEmpty)
        #expect(ramps.contains { $0.from < 1 || $0.to < 1 })
    }

    @Test func speechMappingIncludesTrimAndFractionalSpeed() {
        let clip = Clip(mediaRef: "voice", mediaType: .audio, startFrame: 90,
                        durationFrames: 120, trimStartFrame: 30, speed: 0.5)
        let ranges = EditorViewModel.timelineFrames(from: [60..<66, 0..<30, 80..<120], clip: clip, fps: 30)
        #expect(ranges == [150..<162, 190..<210])
    }
}
