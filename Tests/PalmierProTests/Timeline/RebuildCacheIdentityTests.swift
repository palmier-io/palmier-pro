import Foundation
import Testing
@testable import PalmierPro

@Suite("Timeline — rebuild cache identity")
struct RebuildCacheIdentityTests {

    private func timeline() -> Timeline {
        var text = Fixtures.clip(id: "t1", mediaRef: "text", mediaType: .text, start: 10, duration: 30)
        text.textContent = "Hello"
        let video = Fixtures.clip(id: "v1", start: 0, duration: 100)
        return Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video, text]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100)]),
        ])
    }

    @Test func strippingRemovesTextClipsFromAllTracks() {
        let stripped = timeline().strippingTextClips()
        #expect(stripped.tracks.flatMap(\.clips).allSatisfy { $0.mediaType != .text })
        #expect(stripped.tracks.flatMap(\.clips).count == 2)
    }

    @Test func captionEditsKeepStrippedTimelineEqual() {
        let base = timeline()
        var edited = base
        var clip = edited.tracks[0].clips[1]
        clip.textContent = "Different words"
        clip.textStyle = TextStyle(fontSize: 200)
        clip.textAnimation = TextAnimation(preset: .wordPop)
        clip.transform.centerY = 0.2
        edited.tracks[0].clips[1] = clip

        #expect(edited.strippingTextClips() == base.strippingTextClips())
        #expect(edited.totalFrames == base.totalFrames)
    }

    @Test func videoEditsChangeStrippedTimeline() {
        let base = timeline()
        var edited = base
        edited.tracks[0].clips[0].durationFrames = 50

        #expect(edited.strippingTextClips() != base.strippingTextClips())
    }

    @Test func captionExtendingDurationChangesTotalFrames() {
        let base = timeline()
        var edited = base
        edited.tracks[0].clips[1].startFrame = 200

        #expect(edited.strippingTextClips() == base.strippingTextClips())
        #expect(edited.totalFrames != base.totalFrames)
    }
}
