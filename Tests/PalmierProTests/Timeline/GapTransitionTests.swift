import Foundation
import Testing
@testable import PalmierPro

@Suite("Generated gap transitions")
@MainActor
struct GapTransitionTests {
    @Test(arguments: [119, 120, 450, 451])
    func acceptsOnlyFourToFifteenSecondGaps(frameCount: Int) {
        let previous = Fixtures.clip(id: "previous", start: 0, duration: 30)
        let next = Fixtures.clip(id: "next", start: 30 + frameCount, duration: 30)
        let timeline = Fixtures.timeline(
            fps: 30,
            tracks: [Fixtures.videoTrack(id: "video", clips: [previous, next])]
        )
        let gap = GapSelection(
            trackIndex: 0,
            range: FrameRange(start: 30, end: 30 + frameCount)
        )

        let context = GapTransitionPlanner.context(for: gap, in: timeline)

        #expect((context != nil) == (frameCount >= 120 && frameCount <= 450))
    }

    @Test func roundsGenerationUpToCoverFractionalGap() {
        let duration = GapTransitionPlanner.generationDuration(
            gapFrameCount: 165,
            fps: 30,
            supportedDurations: Array(4...15)
        )

        #expect(duration == 6)
    }

    @Test func rejectsFrameRatesOutsideProjectLimits() {
        let previous = Fixtures.clip(id: "previous", start: 0, duration: 121)
        let next = Fixtures.clip(id: "next", start: 605, duration: 121)
        let timeline = Fixtures.timeline(
            fps: 121,
            tracks: [Fixtures.videoTrack(clips: [previous, next])]
        )

        let context = GapTransitionPlanner.context(
            for: GapSelection(trackIndex: 0, range: FrameRange(start: 121, end: 605)),
            in: timeline
        )

        #expect(context == nil)
    }

    @Test func computesSpeedThatPreservesExactGapSpan() throws {
        let speed = try #require(GapTransitionPlanner.playbackRate(
            generationDurationSeconds: 6,
            targetFrameCount: 165,
            fps: 30
        ))

        #expect(abs(speed - (180.0 / 165.0)) < 0.000_001)
    }

    @Test(arguments: Array(120...450))
    func speedConsumesEveryRequestedSourceFrame(targetFrameCount: Int) throws {
        let duration = Int(ceil(Double(targetFrameCount) / 30))
        let speed = try #require(GapTransitionPlanner.playbackRate(
            generationDurationSeconds: duration,
            targetFrameCount: targetFrameCount,
            fps: 30
        ))

        #expect(Int((Double(targetFrameCount) * speed).rounded()) == duration * 30)
    }

    @Test func choosesAspectRatioClosestToTimelineCanvas() {
        let aspectRatio = GapTransitionPlanner.closestAspectRatio(
            width: 1080,
            height: 1920,
            supportedAspectRatios: ["16:9", "1:1", "9:16"]
        )

        #expect(aspectRatio == "9:16")
    }

    @Test func placesRetimeAndUndoAsOneTimelineEdit() throws {
        let previous = Fixtures.clip(id: "previous", start: 0, duration: 30)
        let next = Fixtures.clip(id: "next", start: 195, duration: 30)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(
            fps: 30,
            tracks: [Fixtures.videoTrack(id: "video", clips: [previous, next])]
        )
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)

        let placeholder = MediaAsset(
            id: "generated",
            url: URL(fileURLWithPath: "/tmp/generated-transition.mp4"),
            type: .video,
            name: "Generated Transition",
            duration: 6
        )
        editor.mediaAssets = [placeholder]
        let gap = GapSelection(
            trackIndex: 0,
            range: FrameRange(start: 30, end: 195)
        )
        editor.selectedGap = gap
        let context = try #require(GapTransitionPlanner.context(for: gap, in: editor.timeline))

        let clipId = try #require(editor.placeGeneratingGapTransition(
            placeholderId: placeholder.id,
            placement: PendingGapTransitionPlacement(
                context: context,
                timelineRevision: editor.timelineRenderRevision,
                firstFrameAssetId: "first",
                lastFrameAssetId: "last",
                previousMediaRef: "media-1",
                nextMediaRef: "media-1",
                previousMediaURL: nil,
                nextMediaURL: nil
            ),
            generationDurationSeconds: 6
        ))
        let clip = try #require(editor.clipFor(id: clipId))

        #expect(clip.startFrame == 30)
        #expect(clip.durationFrames == 165)
        #expect(clip.endFrame == 195)
        #expect(abs(clip.speed - (180.0 / 165.0)) < 0.000_001)
        #expect(undoManager.undoActionName == "Add Generated Transition")

        undoManager.undo()
        #expect(editor.clipFor(id: clipId) == nil)
        #expect(editor.selectedGap == gap)
        #expect(editor.selectedClipIds.isEmpty)

        undoManager.redo()
        let restored = try #require(editor.clipFor(id: clipId))
        #expect(restored.endFrame == 195)
        #expect(restored.speed == clip.speed)
        #expect(editor.selectedGap == nil)
        #expect(editor.selectedClipIds == [clipId])
    }

    @Test func refusesPlacementAfterGapChanges() throws {
        let previous = Fixtures.clip(id: "previous", start: 0, duration: 30)
        let next = Fixtures.clip(id: "next", start: 195, duration: 30)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(
            fps: 30,
            tracks: [Fixtures.videoTrack(id: "video", clips: [previous, next])]
        )
        let context = try #require(GapTransitionPlanner.context(
            for: GapSelection(trackIndex: 0, range: FrameRange(start: 30, end: 195)),
            in: editor.timeline
        ))
        editor.timeline.tracks[0].clips.append(
            Fixtures.clip(id: "new", start: 100, duration: 10)
        )

        let issue = editor.gapTransitionPlacementIssue(
            PendingGapTransitionPlacement(
                context: context,
                timelineRevision: editor.timelineRenderRevision,
                firstFrameAssetId: "first",
                lastFrameAssetId: "last",
                previousMediaRef: "media-1",
                nextMediaRef: "media-1",
                previousMediaURL: nil,
                nextMediaURL: nil
            ),
            generationDurationSeconds: 6
        )

        #expect(issue == "The gap changed. Create the transition again.")
    }
}
