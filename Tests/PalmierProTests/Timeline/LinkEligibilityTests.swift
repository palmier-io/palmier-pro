import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — link eligibility")
@MainActor
struct LinkEligibilityTests {

    private func editor() -> EditorViewModel {
        var video = Fixtures.clip(id: "v1", start: 0, duration: 60)
        var audio = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 60)
        video.linkGroupId = "g1"
        audio.linkGroupId = "g1"
        let looseVideo = Fixtures.clip(id: "v2", start: 100, duration: 60)
        let looseAudio = Fixtures.clip(id: "a2", mediaType: .audio, start: 100, duration: 60)
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video, looseVideo]),
            Fixtures.audioTrack(clips: [audio, looseAudio]),
        ])
        return e
    }

    @Test func linkTargetsAcceptsMixedTypeUnlinkedClips() {
        #expect(editor().linkTargets(for: ["v2", "a2"]) == ["v2", "a2"])
    }

    @Test func linkTargetsRejectsSingleClipAndSameType() {
        let e = editor()
        #expect(e.linkTargets(for: ["v2"]) == nil)
        #expect(e.linkTargets(for: ["v1", "v2"])?.contains("a1") == true)
    }

    @Test func linkTargetsRejectsFullyLinkedGroup() {
        #expect(editor().linkTargets(for: ["v1", "a1"]) == nil)
    }

    @Test func linkTargetsRejectsUnknownIds() {
        #expect(editor().linkTargets(for: ["v2", "missing"]) == nil)
    }

    @Test func unlinkTargetsExpandsGroupAndSkipsUnlinked() {
        let e = editor()
        #expect(e.unlinkTargets(for: ["v1"]) == ["v1", "a1"])
        #expect(e.unlinkTargets(for: ["v2", "a2"]).isEmpty)
    }
}
