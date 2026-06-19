import Testing
import AVFoundation
@testable import PalmierPro

@Suite("Custom compositor switching")
struct ColorCompositorWiringTests {

    private func videoComposition(for timeline: Timeline, trackMappings: [TrackMapping] = []) -> AVVideoComposition {
        CompositionBuilder.buildVisuals(
            timeline: timeline,
            trackMappings: trackMappings,
            compositionDuration: CMTime(value: 30, timescale: 30),
            renderSize: CGSize(width: 1920, height: 1080)
        ).videoComposition
    }

    /// A real composition video track mapped to `trackIndex`, so a source layer can be built.
    private func videoMapping(trackIndex: Int) -> TrackMapping {
        let comp = AVMutableComposition()
        let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        return TrackMapping(
            compositionTrack: track,
            kind: .timeline(trackIndex: trackIndex, clipIds: nil),
            naturalSize: CGSize(width: 1920, height: 1080),
            endTime: CMTime(value: 30, timescale: 30),
            isVideo: true
        )
    }

    @Test func plainTimelineKeepsBuiltInCompositor() {
        var clip = Clip(mediaRef: "v", startFrame: 0, durationFrames: 30)
        clip.mediaType = .video
        let timeline = Timeline(tracks: [Track(type: .video, clips: [clip])])
        #expect(videoComposition(for: timeline).customVideoCompositorClass == nil)
    }

    @Test func adjustmentGradeEnablesCustomCompositor() {
        var adj = Clip(mediaRef: "", startFrame: 0, durationFrames: 30)
        adj.mediaType = .adjustment
        adj.colorGrade = ColorGrade(contrast: 25)
        let timeline = Timeline(tracks: [Track(type: .adjustment, clips: [adj])])
        #expect(videoComposition(for: timeline).customVideoCompositorClass == ColorVideoCompositor.self)
    }

    @Test func inactiveAdjustmentKeepsBuiltInCompositor() {
        var adj = Clip(mediaRef: "", startFrame: 0, durationFrames: 30)
        adj.mediaType = .adjustment
        adj.colorGrade = ColorGrade() // no effect
        let timeline = Timeline(tracks: [Track(type: .adjustment, clips: [adj])])
        #expect(videoComposition(for: timeline).customVideoCompositorClass == nil)
    }

    @Test func blendModeEnablesCustomCompositor() {
        var clip = Clip(mediaRef: "v", startFrame: 0, durationFrames: 30)
        clip.mediaType = .video
        clip.blendMode = .multiply
        let timeline = Timeline(tracks: [Track(type: .video, clips: [clip])])
        #expect(videoComposition(for: timeline, trackMappings: [videoMapping(trackIndex: 0)])
            .customVideoCompositorClass == ColorVideoCompositor.self)
    }

    @Test func normalBlendKeepsBuiltInCompositor() {
        var clip = Clip(mediaRef: "v", startFrame: 0, durationFrames: 30)
        clip.mediaType = .video
        clip.blendMode = .normal
        let timeline = Timeline(tracks: [Track(type: .video, clips: [clip])])
        #expect(videoComposition(for: timeline, trackMappings: [videoMapping(trackIndex: 0)])
            .customVideoCompositorClass == nil)
    }

    @Test func chromaKeyEnablesCustomCompositor() {
        var clip = Clip(mediaRef: "v", startFrame: 0, durationFrames: 30)
        clip.mediaType = .video
        clip.chromaKey = ChromaKey(enabled: true)
        let timeline = Timeline(tracks: [Track(type: .video, clips: [clip])])
        #expect(videoComposition(for: timeline, trackMappings: [videoMapping(trackIndex: 0)])
            .customVideoCompositorClass == ColorVideoCompositor.self)
    }
}
