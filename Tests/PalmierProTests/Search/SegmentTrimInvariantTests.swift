import Foundation
import Testing
@testable import PalmierPro

/// Smoke test for the segment-drop trim bug.
///
/// `trimEndFrame` is a TAIL-trim amount (frames cut off the end of the source),
/// per `Clip.sourceDurationFrames = sourceFramesConsumed + trimStartFrame + trimEndFrame`.
/// Therefore a clip created from a dropped source segment must satisfy the
/// invariant: trimStart + consumed + trimEnd == the asset's real frame count.
/// It can never reference more (or fewer) frames than the source actually has.
@MainActor
@Suite("Segment trim source-length invariant")
struct SegmentTrimInvariantTests {
    private func editor(fps: Int = 30) -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(fps: fps, tracks: [Fixtures.videoTrack()])
        return e
    }

    /// 100s asset @ 30fps = 3000 source frames.
    private func asset() -> MediaAsset {
        MediaAsset(url: URL(fileURLWithPath: "/tmp/a.mov"), type: .video, name: "a", duration: 100)
    }

    @Test func midSegmentSourceLengthMatchesAsset() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0, segments: [a.id: 10...14])
        let clip = e.timeline.tracks[0].clips.first
        #expect(clip != nil)
        // Must equal the asset's true frame count (3000), not an inflated/deflated value.
        #expect(clip?.sourceDurationFrames == 3000)
    }

    @Test func endSegmentDoesNotExceedAsset() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0, segments: [a.id: 96...100])
        let clip = e.timeline.tracks[0].clips.first
        // Segment runs to the asset end → nothing trimmed off the tail.
        #expect(clip?.trimEndFrame == 0)
        #expect(clip?.sourceDurationFrames == 3000)
    }
}
