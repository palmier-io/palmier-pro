import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — silence removal")
@MainActor
struct SilenceRemovalViewModelTests {

    @Test func silenceRemovalCandidateNilWhenNoSelection() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])])
        e.selectedClipIds = []
        #expect(e.silenceRemovalCandidate == nil)
    }

    @Test func silenceRemovalCandidateNilWhenUnlinkedMultipleSelected() {
        // Two clips in the same track with no link group → still nil.
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 50),
            Fixtures.clip(id: "c2", start: 50, duration: 50),
        ])])
        e.selectedClipIds = ["c1", "c2"]
        #expect(e.silenceRemovalCandidate == nil)
    }

    @Test func silenceRemovalCandidateNilWhenTextClipSelected() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "t1", mediaType: .text, start: 0, duration: 100),
        ])])
        e.selectedClipIds = ["t1"]
        #expect(e.silenceRemovalCandidate == nil)
    }

    @Test func silenceRemovalCandidateReturnsSingleVideoClip() {
        let e = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 100)
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        e.selectedClipIds = ["c1"]
        #expect(e.silenceRemovalCandidate?.id == "c1")
    }

    @Test func silenceRemovalCandidateLinkedPairPrefersAudioClip() {
        // Linked video+audio pair: selecting both should return the audio clip.
        let e = EditorViewModel()
        var vid = Fixtures.clip(id: "v1", start: 0, duration: 300)
        var aud = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 300)
        let group = "link-group-1"
        vid.linkGroupId = group
        aud.linkGroupId = group
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [vid]),
            Fixtures.audioTrack(clips: [aud]),
        ])
        e.selectedClipIds = ["v1", "a1"]
        #expect(e.silenceRemovalCandidate?.id == "a1")
    }

    @Test func silenceRemovalCandidateLinkedPairFallsBackToVideo() {
        // Linked pair where only a video clip exists (no separate audio clip).
        let e = EditorViewModel()
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 300)
        var v2 = Fixtures.clip(id: "v2", start: 0, duration: 300)
        let group = "link-group-2"
        v1.linkGroupId = group
        v2.linkGroupId = group
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [v1]),
            Fixtures.videoTrack(clips: [v2]),
        ])
        e.selectedClipIds = ["v1", "v2"]
        // Both are video; either is valid — just ensure we get a non-nil result.
        #expect(e.silenceRemovalCandidate != nil)
    }

    @Test func removeSilencesReturnedFramesRemovedViaRipple() {
        // Inject known silence ranges and verify they're removed.
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 300)])])
        let clip = e.timeline.tracks[0].clips[0]
        let silences: [(start: Double, end: Double)] = [(start: 1.0, end: 2.0)]  // 30 frames at 30fps
        let removed = e.removeSilences(clip: clip, silences: silences)
        #expect(removed == 30)
        #expect(e.timeline.tracks[0].endFrame == 270)
    }

    @Test func removeSilencesLinkedPartnerAlsoCut() {
        // When the audio clip is in a link group, the video partner must be cut too.
        let e = EditorViewModel()
        let group = "link-group-3"
        var vid = Fixtures.clip(id: "v1", start: 0, duration: 300)
        var aud = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 300)
        vid.linkGroupId = group
        aud.linkGroupId = group
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [vid]),
            Fixtures.audioTrack(clips: [aud]),
        ])
        let audioClip = e.timeline.tracks[1].clips[0]
        let silences: [(start: Double, end: Double)] = [(start: 1.0, end: 2.0)]  // 30 frames
        e.removeSilences(clip: audioClip, silences: silences)
        // Both tracks must be 270 frames (the ripple engine cuts linked partners).
        #expect(e.timeline.tracks[0].endFrame == 270)  // video
        #expect(e.timeline.tracks[1].endFrame == 270)  // audio
    }
}
