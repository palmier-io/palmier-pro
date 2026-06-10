import Foundation
import Testing
@testable import PalmierPro

/// Link groups: clips that share a linkGroupId behave as one unit. Tests the index, expansion,
/// partner lookup, sync-offset detection, and link/unlink commands.
@MainActor
private func makeEditor(_ tracks: [Track] = []) -> EditorViewModel {
    let editor = EditorViewModel()
    editor.timeline = Fixtures.timeline(tracks: tracks)
    return editor
}

@Suite("EditorViewModel — linking")
@MainActor
struct LinkingTests {

    private func clipWithGroup(id: String, group: String?, start: Int = 0, duration: Int = 30, mediaType: ClipType = .video) -> Clip {
        var c = Fixtures.clip(id: id, mediaType: mediaType, start: start, duration: duration)
        c.linkGroupId = group
        return c
    }

    // MARK: - linkIndex

    @Test func linkIndexMapsGroupIDsToMemberClipIDs() {
        let v = clipWithGroup(id: "v", group: "g1")
        let a = clipWithGroup(id: "a", group: "g1", mediaType: .audio)
        let solo = clipWithGroup(id: "solo", group: nil)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [v, solo]),
            Fixtures.audioTrack(clips: [a]),
        ])
        let idx = editor.linkIndex
        #expect(idx["g1"]?.sorted() == ["a", "v"])
        #expect(idx.values.contains(where: { $0.contains("solo") }) == false)
    }

    @Test func linkIndexIsEmptyForUngroupedTimeline() {
        let editor = makeEditor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 30),
        ])])
        #expect(editor.linkIndex.isEmpty)
    }

    // MARK: - expandToLinkGroup

    @Test func expandReturnsInputUnchangedWhenNoneAreLinked() {
        let editor = makeEditor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 30),
        ])])
        #expect(editor.expandToLinkGroup(["a"]) == ["a"])
    }

    @Test func expandPullsInAllPartnersOfATouchedGroup() {
        let v = clipWithGroup(id: "v", group: "g1")
        let a = clipWithGroup(id: "a", group: "g1", mediaType: .audio)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [v]),
            Fixtures.audioTrack(clips: [a]),
        ])
        // Asking for just "v" should return both halves of the group.
        #expect(editor.expandToLinkGroup(["v"]) == ["v", "a"])
    }

    @Test func expandHandlesMultipleGroupsIndependently() {
        let v1 = clipWithGroup(id: "v1", group: "g1")
        let a1 = clipWithGroup(id: "a1", group: "g1", mediaType: .audio)
        let v2 = clipWithGroup(id: "v2", group: "g2", start: 100)
        let a2 = clipWithGroup(id: "a2", group: "g2", start: 100, mediaType: .audio)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [v1, v2]),
            Fixtures.audioTrack(clips: [a1, a2]),
        ])
        let result = editor.expandToLinkGroup(["v1", "v2"])
        #expect(result == ["v1", "a1", "v2", "a2"])
    }

    // MARK: - linkedPartnerIds

    @Test func linkedPartnersExcludeSelf() {
        let v = clipWithGroup(id: "v", group: "g1")
        let a = clipWithGroup(id: "a", group: "g1", mediaType: .audio)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [v]),
            Fixtures.audioTrack(clips: [a]),
        ])
        #expect(editor.linkedPartnerIds(of: "v") == ["a"])
        #expect(editor.linkedPartnerIds(of: "a") == ["v"])
    }

    @Test func linkedPartnersIsEmptyForUngroupedClip() {
        let editor = makeEditor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "solo", start: 0, duration: 30),
        ])])
        #expect(editor.linkedPartnerIds(of: "solo").isEmpty)
    }

    @Test func linkedPartnersIsEmptyForUnknownClip() {
        let editor = makeEditor()
        #expect(editor.linkedPartnerIds(of: "ghost").isEmpty)
    }

    // MARK: - linkGroupOffsets

    @Test func linkGroupOffsetsReturnsEmptyWhenPartnersInSync() {
        // Both clips start at frame 100, both with trimStartFrame=0 → in sync.
        let v = clipWithGroup(id: "v", group: "g1", start: 100)
        let a = clipWithGroup(id: "a", group: "g1", start: 100, mediaType: .audio)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [v]),
            Fixtures.audioTrack(clips: [a]),
        ])
        #expect(editor.linkGroupOffsets().isEmpty)
    }

    @Test func linkGroupOffsetsReportsDeltaForOutOfSyncPartner() {
        // v at frame 100, a at frame 110 — a is 10 frames ahead of the shared zero.
        let v = clipWithGroup(id: "v", group: "g1", start: 100)
        let a = clipWithGroup(id: "a", group: "g1", start: 110, mediaType: .audio)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [v]),
            Fixtures.audioTrack(clips: [a]),
        ])
        let offsets = editor.linkGroupOffsets()
        #expect(offsets["v"] == nil) // v is the earliest, no offset
        #expect(offsets["a"] == 10)
    }

    @Test func linkGroupOffsetsIgnoresSingletonGroups() {
        // A group with only one member can't be out of sync with anything.
        let solo = clipWithGroup(id: "solo", group: "g1")
        let editor = makeEditor([Fixtures.videoTrack(clips: [solo])])
        #expect(editor.linkGroupOffsets().isEmpty)
    }

    // MARK: - linkClips / unlinkClips

    @Test func linkClipsStampsSharedGroupOnTwoOrMoreSelectedClips() {
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let c2 = Fixtures.clip(id: "c2", mediaType: .audio, start: 0, duration: 30)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [c1]),
            Fixtures.audioTrack(clips: [c2]),
        ])
        editor.linkClips(ids: ["c1", "c2"])
        let groups = editor.timeline.tracks.flatMap(\.clips).compactMap(\.linkGroupId)
        #expect(groups.count == 2)
        #expect(Set(groups).count == 1, "both clips should share a single group id")
    }

    @Test func linkClipsRequiresAtLeastTwoClips() {
        // Linking just one clip is meaningless and should be a no-op.
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let editor = makeEditor([Fixtures.videoTrack(clips: [c1])])
        editor.linkClips(ids: ["c1"])
        #expect(editor.timeline.tracks[0].clips[0].linkGroupId == nil)
    }

    @Test func unlinkClipsClearsGroupOnAllPartners() {
        let v = clipWithGroup(id: "v", group: "g1")
        let a = clipWithGroup(id: "a", group: "g1", mediaType: .audio)
        let editor = makeEditor([
            Fixtures.videoTrack(clips: [v]),
            Fixtures.audioTrack(clips: [a]),
        ])
        // Pass just one of the pair; unlink should expand to the partner.
        editor.unlinkClips(ids: ["v"])
        #expect(editor.timeline.tracks[0].clips[0].linkGroupId == nil)
        #expect(editor.timeline.tracks[1].clips[0].linkGroupId == nil)
    }
}
