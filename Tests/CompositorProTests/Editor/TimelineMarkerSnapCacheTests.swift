import Foundation
import Testing
@testable import CompositorPro

@Suite("Timeline marker snap cache")
@MainActor
struct TimelineMarkerSnapCacheTests {

    @Test func snapFramesRefreshAfterMarkerMutations() {
        let editor = EditorViewModel()
        editor.timeline.markers = [TimelineMarker(id: "a", name: "A", startFrame: 40)]
        #expect(editor.timelineMarkerSnapFrames() == [40])
        editor.timeline.markers.append(TimelineMarker(id: "b", name: "B", startFrame: 10))
        #expect(editor.timelineMarkerSnapFrames() == [10, 40])
    }

    @Test func snapFramesRefreshAfterChangeTimelineMarkers() throws {
        let editor = EditorViewModel()
        _ = try editor.changeTimelineMarkers(
            creates: [TimelineMarker(id: "a", name: "A", startFrame: 40)],
            actionName: "Add"
        )
        #expect(editor.timelineMarkerSnapFrames() == [40])
        _ = try editor.changeTimelineMarkers(
            creates: [TimelineMarker(id: "b", name: "B", startFrame: 10)],
            actionName: "Add"
        )
        #expect(editor.timelineMarkerSnapFrames() == [10, 40])
        _ = try editor.changeTimelineMarkers(
            updates: [TimelineMarker(id: "a", name: "A", startFrame: 80)],
            actionName: "Move"
        )
        #expect(editor.timelineMarkerSnapFrames() == [10, 80])
    }

    @Test func exclusionKeepsFramesSharedWithRetainedMarkers() {
        let editor = EditorViewModel()
        let range = TimelineMarker(id: "range", name: "R", startFrame: 10, durationFrames: 20)
        let point = TimelineMarker(id: "point", name: "P", startFrame: 30)
        editor.timeline.markers = [range, point]
        #expect(editor.timelineMarkerSnapFrames() == [10, 30])
        #expect(editor.timelineMarkerSnapFrames(excludingMarkerIds: ["point"]) == [10, 30])
        #expect(editor.timelineMarkerSnapFrames(excludingMarkerIds: ["range"]) == [30])
    }

    @Test func undoRestoresSnapFrames() throws {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undo.attach(undo)
        _ = try editor.changeTimelineMarkers(
            creates: [TimelineMarker(id: "a", name: "A", startFrame: 40)],
            actionName: "Add"
        )
        #expect(editor.timelineMarkerSnapFrames() == [40])
        _ = try editor.changeTimelineMarkers(
            creates: [TimelineMarker(id: "b", name: "B", startFrame: 10)],
            actionName: "Add"
        )
        #expect(editor.timelineMarkerSnapFrames() == [10, 40])
        undo.undo()
        #expect(editor.timelineMarkerSnapFrames() == [40])
    }
}
