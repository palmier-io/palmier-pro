import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@Suite("EditorViewModel - select forward")
@MainActor
struct TimelineForwardSelectionTests {

    @Test func selectForwardOnTrackIncludesAnchorAndLaterClipsOnlyOnAnchorTrack() {
        let e = editor([
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "before", start: 0, duration: 20),
                Fixtures.clip(id: "anchor", start: 30, duration: 20),
                Fixtures.clip(id: "after", start: 70, duration: 20),
            ]),
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: "other", mediaType: .audio, start: 40, duration: 20),
            ]),
        ])

        e.selectForward(from: "anchor", scope: .track)

        #expect(e.selectedClipIds == ["anchor", "after"])
    }

    @Test func selectForwardOnAllTracksUsesAnchorFrameAcrossTimeline() {
        let e = editor([
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "before", start: 0, duration: 20),
                Fixtures.clip(id: "anchor", start: 30, duration: 20),
            ]),
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: "sameFrame", mediaType: .audio, start: 30, duration: 20),
                Fixtures.clip(id: "after", mediaType: .audio, start: 90, duration: 20),
            ]),
        ])

        e.selectForward(from: "anchor", scope: .allTracks)

        #expect(e.selectedClipIds == ["anchor", "sameFrame", "after"])
    }

    @Test func selectForwardExpandsLinkedPartners() {
        var anchor = Fixtures.clip(id: "anchor", start: 30, duration: 20)
        anchor.linkGroupId = "g1"
        var linkedAudio = Fixtures.clip(id: "linkedAudio", mediaType: .audio, start: 10, duration: 20)
        linkedAudio.linkGroupId = "g1"
        let e = editor([
            Fixtures.videoTrack(clips: [anchor]),
            Fixtures.audioTrack(clips: [linkedAudio]),
        ])

        e.selectForward(from: "anchor", scope: .track)

        #expect(e.selectedClipIds == ["anchor", "linkedAudio"])
    }

    @Test func currentSelectionUsesEarliestSelectedClipAsAnchor() {
        let e = editor([
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "first", start: 20, duration: 20),
                Fixtures.clip(id: "second", start: 60, duration: 20),
                Fixtures.clip(id: "third", start: 100, duration: 20),
            ]),
        ])
        e.selectedClipIds = ["second", "third"]

        e.selectForwardFromCurrentSelection(scope: .track)

        #expect(e.selectedClipIds == ["second", "third"])
    }
}
