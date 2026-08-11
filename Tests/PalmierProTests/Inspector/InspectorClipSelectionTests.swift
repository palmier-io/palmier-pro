import Testing
@testable import PalmierPro

@Suite struct InspectorClipSelectionTests {
    @Test func resolvesSelectedClipsByInspectorCategory() {
        let text = Fixtures.clip(id: "text", mediaRef: "text", mediaType: .text, start: 0, duration: 30)
        let video = Fixtures.clip(id: "video", mediaRef: "video", mediaType: .video, start: 30, duration: 30)
        let audio = Fixtures.clip(id: "audio", mediaRef: "audio", mediaType: .audio, start: 0, duration: 60)
        let unselected = Fixtures.clip(id: "other", mediaRef: "other", mediaType: .text, start: 60, duration: 30)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [text, video, unselected]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        let selection = InspectorClipSelection.resolve(
            timeline: timeline,
            selectedIds: [text.id, video.id, audio.id]
        )

        #expect(selection.textClips.map(\.id) == [text.id])
        #expect(selection.nonTextVisualClips.map(\.id) == [video.id])
        #expect(selection.audioClips.map(\.id) == [audio.id])
        #expect(selection.firstVisualClip?.id == text.id)
        #expect(selection.clipCount == 3)
    }

    @Test func largeCaptionSelectionResolvesWithinInteractionBudget() {
        let captions = (0..<10_000).map { index in
            Fixtures.clip(
                id: "caption-\(index)",
                mediaRef: "caption-media",
                mediaType: .text,
                start: index * 30,
                duration: 30
            )
        }
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: captions)])
        let selectedIds = Set(captions.map(\.id))

        var selection = InspectorClipSelection()
        let duration = ContinuousClock().measure {
            selection = InspectorClipSelection.resolve(timeline: timeline, selectedIds: selectedIds)
        }

        #expect(selection.textClips.count == captions.count)
        #expect(duration < .milliseconds(250))
    }
}
