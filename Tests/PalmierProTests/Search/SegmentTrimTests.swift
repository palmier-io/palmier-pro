import Foundation
import Testing
@testable import PalmierPro

/// Dragging a search "moment" places a clip trimmed to the segment.
@MainActor
@Suite("Segment trim placement")
struct SegmentTrimTests {
    private func editor(fps: Int = 30) -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(fps: fps, tracks: [Fixtures.videoTrack(label: "V1")])
        return e
    }

    private func asset() -> MediaAsset {
        MediaAsset(url: URL(fileURLWithPath: "/tmp/a.mov"), type: .video, name: "a", duration: 100)
    }

    @Test func clipDurationFromSegment() {
        let e = editor()
        #expect(e.clipDurationFrames(for: asset(), segment: nil) == 3000)   // full 100s @ 30fps
        #expect(e.clipDurationFrames(for: asset(), segment: 10...14) == 120) // 4s window
    }

    @Test func placesTrimmedClip() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0, segments: [a.id: 10...14])
        let clip = e.timeline.tracks[0].clips.first
        #expect(clip?.trimStartFrame == 300)   // 10s × 30
        #expect(clip?.trimEndFrame == 420)     // trimStart + 120
        #expect(clip?.durationFrames == 120)
    }

    @Test func noSegmentPlacesFullClip() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0)
        let clip = e.timeline.tracks[0].clips.first
        #expect(clip?.trimStartFrame == 0)
        #expect(clip?.durationFrames == 3000)
    }

    /// Fence-post: a segment ending exactly at the asset end yields an exclusive
    /// trimEnd equal to the asset's frame count — valid, not an overrun.
    @Test func segmentAtAssetEndStaysInBounds() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0, segments: [a.id: 96...100])
        let clip = e.timeline.tracks[0].clips.first
        #expect(clip?.trimEndFrame == 3000)    // 100s × 30, exclusive end
    }
}
