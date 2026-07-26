import Foundation
import Testing
@testable import PalmierPro

@MainActor
struct AITransitionPlacementTests {

    private func editorWithGap() -> (EditorViewModel, UndoManager) {
        let e = EditorViewModel()
        e.timeline.tracks = [Fixtures.videoTrack(clips: [
            Fixtures.clip(start: 0, duration: 100),
            Fixtures.clip(start: 160, duration: 100),
        ])]
        let undo = UndoManager()
        e.undo.attach(undo)
        undo.removeAllActions()
        return (e, undo)
    }

    private func placement(for e: EditorViewModel) -> PendingTransitionPlacement {
        PendingTransitionPlacement(
            timelineId: e.activeTimelineId, trackIndex: 0, gapStartFrame: 100, gapLengthFrames: 60
        )
    }

    @Test func placesPlaceholderIntoEmptyGapWithUndo() {
        let (e, undo) = editorWithGap()
        let asset = MediaAsset(id: "gen-1", url: URL(fileURLWithPath: "/tmp/x.mp4"), type: .video, name: "gen", duration: 2)
        e.mediaAssets.append(asset)

        let clipId = e.placeGeneratingTransitionClip(placeholderId: "gen-1", placement: placement(for: e))

        let clip = e.timeline.tracks[0].clips.first { $0.id == clipId }
        #expect(clip?.startFrame == 100)
        #expect(clip?.durationFrames == 60)
        #expect(undo.canUndo)
        undo.undo()
        #expect(e.timeline.tracks[0].clips.count == 2)
    }

    @Test func refusesWhenGapIsOccupied() {
        let (e, undo) = editorWithGap()
        let asset = MediaAsset(id: "gen-1", url: URL(fileURLWithPath: "/tmp/x.mp4"), type: .video, name: "gen", duration: 2)
        e.mediaAssets.append(asset)
        e.timeline.tracks[0].clips.append(Fixtures.clip(start: 120, duration: 20))

        let clipId = e.placeGeneratingTransitionClip(placeholderId: "gen-1", placement: placement(for: e))

        #expect(clipId == nil)
        #expect(e.timeline.tracks[0].clips.count == 3)
        #expect(!undo.canUndo)
    }

    @Test func gapHitTestFindsGapBetweenTwoClips() {
        let (e, _) = editorWithGap()
        let view = TimelineView(editor: e)
        let geometry = TimelineGeometry(
            pixelsPerFrame: 1,
            trackHeights: e.timeline.tracks.map(\.displayHeight)
        )
        let point = NSPoint(x: 130, y: Double(geometry.trackY(at: 0)) + 10)

        let trackIndex = geometry.trackAt(y: point.y)
        let gap = view.inputController.hitTestGap(at: point, trackIndex: trackIndex, geometry: geometry)

        #expect(trackIndex == 0)
        #expect(gap == GapSelection(trackIndex: 0, range: FrameRange(start: 100, end: 160)))
    }

    @Test(arguments: [
        (2.0, [4, 6, 8], 4),
        (7.2, [4, 6, 8], 8),
        (5.0, [4, 6, 8], 4),
        (12.0, [4, 6, 8], 8),
        (2.4, [Int](), 2),
    ]) func seedDurationSnapsToNearestSupported(seconds: Double, durations: [Int], expected: Int) {
        #expect(EditorViewModel.nearestSupportedDuration(seconds: seconds, in: durations) == expected)
    }

    @Test func seedIsStaleAfterTimelineSwitchOrFilledGap() {
        let (e, _) = editorWithGap()
        let placement = placement(for: e)
        #expect(e.transitionSeedIsCurrent(placement))

        e.timeline.tracks[0].clips.append(Fixtures.clip(start: 120, duration: 20))
        #expect(!e.transitionSeedIsCurrent(placement))
        e.timeline.tracks[0].clips.removeLast()

        let other = e.createTimeline(activate: true)
        #expect(!e.transitionSeedIsCurrent(placement))
        e.activateTimeline(placement.timelineId)
        e.deleteTimeline(other)
        #expect(e.transitionSeedIsCurrent(placement))
    }

    @Test func finalizeRetimesClipToFillGapExactly() {
        let (e, _) = editorWithGap()
        e.timeline.tracks[0].clips.append(Fixtures.clip(mediaRef: "gen-1", start: 100, duration: 60))
        let realSeconds = 4.0
        let asset = MediaAsset(id: "gen-1", url: URL(fileURLWithPath: "/tmp/x.mp4"), type: .video, name: "gen", duration: realSeconds)

        e.finalizeTransitionClip(placeholderId: "gen-1", asset: asset)

        let clip = e.timeline.tracks[0].clips.first { $0.mediaRef == "gen-1" }
        let realFrames = Double(realSeconds) * Double(e.timeline.fps)
        #expect(clip?.durationFrames == 60)
        #expect(clip?.speed == realFrames / 60)
        #expect(clip?.sourceFramesConsumed == Int(realFrames))
    }
}
