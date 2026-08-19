import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — preview selection")
@MainActor
struct PreviewSelectionTests {
    @Test func selectingClipClearsGapSelection() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "clip", start: 0, duration: 20)]),
        ])
        editor.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 50, end: 100))
        editor.selectedTimelineMarkerIds = ["marker"]

        editor.selectPreviewClip("clip")

        #expect(editor.selectedClipIds == ["clip"])
        #expect(editor.selectedGap == nil)
        #expect(editor.selectedTimelineMarkerIds.isEmpty)
    }

    @Test func selectingSelectedClipPreservesMultiSelection() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "first", start: 0, duration: 20),
                Fixtures.clip(id: "second", start: 100, duration: 20),
            ]),
        ])
        editor.selectedClipIds = ["first", "second"]
        editor.selectedTimelineMarkerIds = ["marker"]

        editor.selectPreviewClip("first")

        #expect(editor.selectedClipIds == ["first", "second"])
        #expect(editor.selectedTimelineMarkerIds.isEmpty)
    }

    @Test func rotatedTextUsesRotatedHitTarget() {
        let editor = EditorViewModel()
        var text = Fixtures.clip(id: "text", mediaRef: "", mediaType: .text, start: 0, duration: 20)
        text.transform = Transform(width: 0.6, height: 0.1, rotation: 90)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])
        timeline.width = 320
        timeline.height = 180
        editor.timeline = timeline

        let rotatedOnlyPoint = PreviewHitTester.clipID(
            at: CGPoint(x: 160, y: 45),
            viewSize: CGSize(width: 320, height: 180),
            editor: editor
        )
        let unrotatedOnlyPoint = PreviewHitTester.clipID(
            at: CGPoint(x: 100, y: 90),
            viewSize: CGSize(width: 320, height: 180),
            editor: editor
        )

        #expect(rotatedOnlyPoint == "text")
        #expect(unrotatedOnlyPoint == nil)
    }

    @Test func tiltedTextUsesProjectedHitTarget() {
        let editor = EditorViewModel()
        var text = Fixtures.clip(id: "text", mediaRef: "", mediaType: .text, start: 0, duration: 20)
        text.transform = Transform(width: 0.6, height: 0.2, rotationY: 60)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [text])])
        timeline.width = 320
        timeline.height = 180
        editor.timeline = timeline

        #expect(PreviewHitTester.clipID(
            at: CGPoint(x: 160, y: 90),
            viewSize: CGSize(width: 320, height: 180),
            editor: editor
        ) == "text")
        #expect(PreviewHitTester.clipID(
            at: CGPoint(x: 90, y: 90),
            viewSize: CGSize(width: 320, height: 180),
            editor: editor
        ) == nil)
    }

    @Test func selectAdjacentPreviewTabWrapsAcrossOpenTabs() {
        let editor = EditorViewModel()
        #expect(editor.selectAdjacentPreviewTab(delta: 1) == false)
        let clip = PreviewTab.mediaAsset(id: "clip", name: "Clip", type: .video)
        editor.previewTabs = [.timeline, clip]
        editor.activePreviewTabId = PreviewTab.timeline.id
        #expect(editor.selectAdjacentPreviewTab(delta: 1))
        #expect(editor.activePreviewTabId == clip.id)
        #expect(editor.selectAdjacentPreviewTab(delta: 1))
        #expect(editor.activePreviewTabId == PreviewTab.timeline.id)
        #expect(editor.selectAdjacentPreviewTab(delta: -1))
        #expect(editor.activePreviewTabId == clip.id)
    }
}
