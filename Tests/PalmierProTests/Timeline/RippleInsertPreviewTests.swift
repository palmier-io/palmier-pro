import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func previewEditor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@MainActor
private func asset(id: String, type: ClipType, duration: Double, hasAudio: Bool? = nil) -> MediaAsset {
    let asset = MediaAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id)"), type: type, name: id, duration: duration)
    if let hasAudio { asset.hasAudio = hasAudio }
    return asset
}

@Suite("EditorViewModel - ripple insert preview")
@MainActor
struct RippleInsertPreviewTests {

    @Test func mixedVisualAndAudioOnlyDropUsesSeparateTargetTrackPushes() {
        var videoTrack = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "video-tail", start: 100, duration: 30),
        ])
        videoTrack.syncLocked = false
        var audioTrack = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "audio-tail", mediaType: .audio, start: 100, duration: 30),
        ])
        audioTrack.syncLocked = false
        let e = previewEditor([videoTrack, audioTrack])
        let video = asset(id: "video", type: .video, duration: 2)
        let audio = asset(id: "audio", type: .audio, duration: 1)

        let plan = e.resolveDropPlan(cursor: .existingTrack(0), assets: [video, audio], atFrame: 50)
        let preview = e.planRippleInsertPreview(dropPlan: plan, atFrame: 50)

        #expect(plan.visualAssets.map(\.id) == ["video"])
        #expect(plan.audioOnlyAssets.map(\.id) == ["audio"])
        #expect(preview?.gapRangesByTrackIndex[0] == FrameRange(start: 50, end: 110))
        #expect(preview?.gapRangesByTrackIndex[1] == FrameRange(start: 50, end: 80))
        #expect(preview?.shiftDeltasByClipId["video-tail"] == 60)
        #expect(preview?.shiftDeltasByClipId["audio-tail"] == 30)
    }

    @Test func syncLockedFollowerReceivesBothMixedDropPushes() {
        var videoTrack = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "video-tail", start: 100, duration: 30),
        ])
        videoTrack.syncLocked = false
        var audioTrack = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "audio-tail", mediaType: .audio, start: 100, duration: 30),
        ])
        audioTrack.syncLocked = false
        var syncTrack = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "sync-tail", mediaType: .audio, start: 100, duration: 30),
        ])
        syncTrack.syncLocked = true
        let e = previewEditor([videoTrack, audioTrack, syncTrack])
        let video = asset(id: "video", type: .video, duration: 2)
        let audio = asset(id: "audio", type: .audio, duration: 1)

        let plan = e.resolveDropPlan(cursor: .existingTrack(0), assets: [video, audio], atFrame: 50)
        let preview = e.planRippleInsertPreview(dropPlan: plan, atFrame: 50)

        #expect(preview?.gapRangesByTrackIndex[2] == FrameRange(start: 50, end: 140))
        #expect(preview?.shiftDeltasByClipId["sync-tail"] == 90)
    }

    @Test func newTrackDropShowsShiftedVisualAndAudioTargetGaps() {
        var videoTrack = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "video-tail", start: 100, duration: 30),
        ])
        videoTrack.syncLocked = false
        var audioTrack = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "audio-tail", mediaType: .audio, start: 100, duration: 30),
        ])
        audioTrack.syncLocked = false
        let e = previewEditor([videoTrack, audioTrack])
        let video = asset(id: "video", type: .video, duration: 2)
        let audio = asset(id: "audio", type: .audio, duration: 1)

        let plan = e.resolveDropPlan(cursor: .newTrackAt(1), assets: [video, audio], atFrame: 50)
        let preview = e.planRippleInsertPreview(dropPlan: plan, atFrame: 50)

        #expect(plan.visualTarget == .newTrackAt(1))
        #expect(plan.audioTarget == .newTrackAt(1))
        #expect(preview?.newTrackGapRangesByTarget[.newTrackAt(1)] == FrameRange(start: 50, end: 110))
        #expect(preview?.newTrackGapRangesByTarget[.newTrackAt(2)] == FrameRange(start: 50, end: 80))
        #expect(preview?.gapRangesByTrackIndex.isEmpty == true)
        #expect(preview?.shiftDeltasByClipId.isEmpty == true)
    }
}
