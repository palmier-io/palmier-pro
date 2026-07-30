import Foundation
import Testing
@testable import PalmierPro

@Suite("Track solo — derived audition state")
struct TrackSoloTests {

    private func videoTrack(id: String, soloed: Bool = false, hidden: Bool = false, link: String? = nil) -> Track {
        var clip = Fixtures.clip(mediaType: .video, start: 0, duration: 30)
        clip.linkGroupId = link
        var t = Fixtures.videoTrack(id: id, clips: [clip])
        t.soloed = soloed
        t.hidden = hidden
        return t
    }

    private func audioTrack(id: String, soloed: Bool = false, muted: Bool = false, link: String? = nil) -> Track {
        var clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 30)
        clip.linkGroupId = link
        var t = Fixtures.audioTrack(id: id, clips: [clip])
        t.soloed = soloed
        t.muted = muted
        return t
    }

    @Test("Soloing one video track hides the other video tracks")
    func soloingVideoHidesOthers() {
        let tl = Fixtures.timeline(tracks: [
            videoTrack(id: "v0", soloed: true),
            videoTrack(id: "v1"),
            videoTrack(id: "v2"),
        ])
        #expect(tl.effectiveHidden(for: tl.tracks[0]) == false)
        #expect(tl.effectiveHidden(for: tl.tracks[1]) == true)
        #expect(tl.effectiveHidden(for: tl.tracks[2]) == true)
    }

    @Test("Linked audio follows a soloed video track; unrelated audio is silenced")
    func linkedAudioFollowsVideoSolo() {
        let tl = Fixtures.timeline(tracks: [
            videoTrack(id: "v0", soloed: true, link: "L1"),
            audioTrack(id: "a-linked", link: "L1"),
            audioTrack(id: "a-music"),
        ])
        #expect(tl.effectiveMuted(for: tl.tracks[1]) == false)
        #expect(tl.effectiveMuted(for: tl.tracks[2]) == true)
    }

    @Test("Un-soloing collapses effective state back to the user's stored mute/hide")
    func unsoloingRestoresStoredFlags() {
        var tl = Fixtures.timeline(tracks: [
            videoTrack(id: "v0", soloed: true),
            videoTrack(id: "v1", hidden: true),
            audioTrack(id: "a0", muted: true),
        ])
        // Stored flags are never mutated by solo.
        #expect(tl.tracks[1].hidden == true)
        #expect(tl.tracks[2].muted == true)

        tl.tracks[0].soloed = false
        #expect(tl.effectiveHidden(for: tl.tracks[0]) == false)
        #expect(tl.effectiveHidden(for: tl.tracks[1]) == true)
        #expect(tl.effectiveMuted(for: tl.tracks[2]) == true)
    }

    @Test("Legacy project JSON without a soloed key still decodes")
    func decodesLegacyTrackWithoutSoloed() throws {
        let json = Data(#"{"id":"t1","type":"audio","muted":true,"hidden":false,"syncLocked":true,"clips":[]}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: json)
        #expect(track.soloed == false)
        #expect(track.muted == true)
    }

    @MainActor
    @Test("toggleTrackSolo is reversible and leaves other tracks' stored flags untouched")
    func toggleSoloDoesNotBatchFlipStoredFlags() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            videoTrack(id: "v0"),
            videoTrack(id: "v1", hidden: true),
            audioTrack(id: "a0", muted: true),
        ])

        e.toggleTrackSolo(trackIndex: 0)
        #expect(e.timeline.tracks[0].soloed == true)
        // No other track's stored state was flipped.
        #expect(e.timeline.tracks[1].hidden == true)
        #expect(e.timeline.tracks[1].soloed == false)
        #expect(e.timeline.tracks[2].muted == true)
        #expect(e.timeline.tracks[2].soloed == false)

        e.toggleTrackSolo(trackIndex: 0)
        #expect(e.timeline.tracks[0].soloed == false)
        #expect(e.timeline.tracks[1].hidden == true)
        #expect(e.timeline.tracks[2].muted == true)
    }

    @MainActor
    @Test("Soloing a linked video also solos its linked audio track")
    func soloingVideoAlsoSolosLinkedAudio() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            videoTrack(id: "v0", link: "L1"),
            audioTrack(id: "a-linked", link: "L1"),
            audioTrack(id: "a-music"),
        ])
        e.toggleTrackSolo(trackIndex: 0)
        #expect(e.timeline.tracks[0].soloed == true)
        #expect(e.timeline.tracks[1].soloed == true)
        #expect(e.timeline.tracks[2].soloed == false)
    }

    @MainActor
    @Test("Plain solo is exclusive — a second solo replaces the first")
    func plainSoloIsExclusive() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [videoTrack(id: "v0"), videoTrack(id: "v1")])
        e.toggleTrackSolo(trackIndex: 0)
        e.toggleTrackSolo(trackIndex: 1)
        #expect(e.timeline.tracks[0].soloed == false)
        #expect(e.timeline.tracks[1].soloed == true)
    }

    @MainActor
    @Test("Shift-click adds to the solo set instead of replacing it")
    func shiftSoloIsAdditive() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [videoTrack(id: "v0"), videoTrack(id: "v1")])
        e.toggleTrackSolo(trackIndex: 0)
        e.toggleTrackSolo(trackIndex: 1, exclusive: false)
        #expect(e.timeline.tracks[0].soloed == true)
        #expect(e.timeline.tracks[1].soloed == true)
    }

    @MainActor
    @Test("Clicking the only soloed track clears the solo")
    func clickingOnlySoloClearsIt() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [videoTrack(id: "v0"), videoTrack(id: "v1")])
        e.toggleTrackSolo(trackIndex: 0)
        e.toggleTrackSolo(trackIndex: 0)
        #expect(e.timeline.tracks[0].soloed == false)
        #expect(e.timeline.tracks[1].soloed == false)
    }
}
