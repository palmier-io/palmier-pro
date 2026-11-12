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

    @Test func oneSecondTrimShiftsTwoSecondEventToOneSecondIntoClip() {
        let clip = Clip(mediaRef: "voice", mediaType: .audio, startFrame: 0,
                        durationFrames: 90, trimStartFrame: 30)
        let dips = CompositionBuilder.gainDips(
            clip: clip, timescale: 30, regions: [.init(start: 2.0, end: 2.2)],
            depthDB: -24, fadeSeconds: 0.03)
        #expect(dips.count == 1)
        #expect(dips.first?.start == 30)
        #expect(dips.first?.end == 36)
        let ramps = CompositionBuilder.planVolumeRamps(clip: clip, timescale: 30, dips: dips)
        #expect(overlaps(ramps).isEmpty)
    }

    @Test func fractionalSpeedAndNonzeroStart() {
        let clip = Clip(mediaRef: "voice", mediaType: .audio, startFrame: 100,
                        durationFrames: 60, trimStartFrame: 45, speed: 1.5)
        let dips = CompositionBuilder.gainDips(
            clip: clip, timescale: 30, regions: [.init(start: 2.5, end: 3.0)],
            depthDB: -18, fadeSeconds: 0.03)
        #expect(dips.count == 1)
        #expect(dips.first?.start == 120)
        #expect(dips.first?.end == 130)
        let ramps = CompositionBuilder.planVolumeRamps(clip: clip, timescale: 30, dips: dips)
        #expect(overlaps(ramps).isEmpty)
    }

    @Test func splitClipsSmoothlyAttenuateAcrossCut() {
        let clip1 = Clip(mediaRef: "voice", mediaType: .audio, startFrame: 0,
                         durationFrames: 60, trimStartFrame: 0)
        let clip2 = Clip(mediaRef: "voice", mediaType: .audio, startFrame: 60,
                         durationFrames: 60, trimStartFrame: 60)
        let event = BreathDetector.Region(start: 1.8, end: 2.2)
        let dips1 = CompositionBuilder.gainDips(clip: clip1, timescale: 30, regions: [event],
                                                depthDB: -24, fadeSeconds: 0.03)
        let dips2 = CompositionBuilder.gainDips(clip: clip2, timescale: 30, regions: [event],
                                                depthDB: -24, fadeSeconds: 0.03)
        #expect(dips1.first?.start == 54)
        #expect(dips1.first?.end == 60)
        #expect(dips1.first?.fadeOutStart == 60)
        #expect(dips2.first?.start == 60)
        #expect(dips2.first?.end == 66)
        #expect(dips2.first?.fadeInEnd == 60)
        let ramps1 = CompositionBuilder.planVolumeRamps(clip: clip1, timescale: 30, dips: dips1)
        let ramps2 = CompositionBuilder.planVolumeRamps(clip: clip2, timescale: 30, dips: dips2)
        #expect(overlaps(ramps1).isEmpty)
        #expect(overlaps(ramps2).isEmpty)
        #expect(overlaps(ramps1 + ramps2).isEmpty)
    }

    @Test func nestedTimelineWithDipsAndCarrierRampsPreservesContiguity() {
        var child = Clip(mediaRef: "child_voice", mediaType: .audio, startFrame: 0, durationFrames: 120)
        child.volumeTrack = .init(keyframes: [.init(frame: 0, value: 0), .init(frame: 60, value: -6), .init(frame: 120, value: 0)])
        var carrier = Clip(mediaRef: "carrier", mediaType: .audio, startFrame: 30, durationFrames: 120)
        carrier.fadeInFrames = 15
        carrier.fadeOutFrames = 15
        let dips = [CompositionBuilder.AudioGainDip(start: 40, fadeInEnd: 45, fadeOutStart: 70, end: 75, gain: 0.2)]
        let ramps = CompositionBuilder.planVolumeRamps(clip: child, timescale: 30, carrier: carrier, gain: 1, dips: dips)
        #expect(overlaps(ramps).isEmpty)
        #expect(ramps.first?.range.start == CMTime(value: 0, timescale: 30))
        #expect(ramps.last?.range.end == CMTime(value: 120, timescale: 30))
    }

    @Test func overlappingBreathsAndSibilanceDipsPreserveNonOverlappingRamps() {
        var clip = Clip(mediaRef: "voice", mediaType: .audio, startFrame: 0, durationFrames: 90)
        clip.fadeInFrames = 10
        clip.fadeOutFrames = 10
        let breathDips = CompositionBuilder.gainDips(
            clip: clip, timescale: 30,
            regions: [.init(start: 0.2, end: 0.6), .init(start: 0.4, end: 0.8)],
            depthDB: -24, fadeSeconds: 0.03)
        let deessDips = CompositionBuilder.gainDips(
            clip: clip, timescale: 30,
            regions: [.init(start: 0.3, end: 0.5)],
            depthDB: -12, fadeSeconds: 0.01)
        let allDips = breathDips + deessDips
        let ramps = CompositionBuilder.planVolumeRamps(clip: clip, timescale: 30, dips: allDips)
        #expect(overlaps(ramps).isEmpty)
        #expect(ramps.first?.range.start == CMTime(value: 0, timescale: 30))
        #expect(ramps.last?.range.end == CMTime(value: 90, timescale: 30))
    }
}
