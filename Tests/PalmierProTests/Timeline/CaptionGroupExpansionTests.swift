import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — caption group expansion")
@MainActor
struct CaptionGroupExpansionTests {

    private func textClip(_ id: String, group: String? = nil, start: Int) -> Clip {
        var c = Fixtures.clip(id: id, mediaRef: "text", mediaType: .text, start: start, duration: 10)
        c.captionGroupId = group
        c.textContent = id
        return c
    }

    private func editor() -> EditorViewModel {
        let e = EditorViewModel()
        var audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 100)
        audio.captionGroupId = "g1"
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                textClip("a1", group: "g1", start: 0),
                textClip("a2", group: "g1", start: 10),
                textClip("b1", group: "g2", start: 20),
                textClip("solo", start: 30),
            ]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        return e
    }

    @Test func batchExpansionMatchesPerClipExpansion() {
        let e = editor()
        let ids = ["a1", "b1", "solo", "missing"]
        var seen = Set<String>()
        let perClip = ids.flatMap { e.captionGroupTextClipIds(for: $0) }
            .filter { seen.insert($0).inserted }
        let batch = e.captionGroupTextClipIds(expanding: ids)
        #expect(Set(batch) == Set(perClip))
        #expect(batch.count == perClip.count)
    }

    @Test func batchExpansionCoversWholeGroupAndDeduplicates() {
        let e = editor()
        let batch = e.captionGroupTextClipIds(expanding: ["a1", "a2", "a1"])
        #expect(batch == ["a1", "a2"])
    }

    @Test func groupedNonTextClipExpandsToGroupTextClipsOnly() {
        let e = editor()
        #expect(e.captionGroupTextClipIds(expanding: ["audio"]) == ["a1", "a2"])
    }

    @Test func ungroupedAndUnknownClipsFallBackToThemselves() {
        let e = editor()
        #expect(e.captionGroupTextClipIds(expanding: ["solo"]) == ["solo"])
        #expect(e.captionGroupTextClipIds(expanding: ["missing"]) == ["missing"])
    }
}
