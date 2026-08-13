import Foundation
import Testing
@testable import PalmierPro

@Suite("Timeline markers")
@MainActor
struct TimelineMarkerTests {
    @Test func markersPersistWithoutChangingContentDuration() throws {
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])])
        timeline.markers = [TimelineMarker(name: "Review", startFrame: 40, durationFrames: 10, color: .init(r: 1, g: 0, b: 0), comment: "Tighten")]
        let file = ProjectFile(timelines: [timeline])
        let decoded = try JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(file))
        #expect(decoded.timelines[0].markers == timeline.markers)
        #expect(decoded.timelines[0].totalFrames == 30)
        #expect(decoded.timelines[0].displayFrames == 50)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as? [String: Any])
        object.removeValue(forKey: "markers")
        let withoutMarkers = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Timeline.self, from: withoutMarkers).markers.isEmpty)
    }
    @Test func duplicateTimelineFreshensMarkerIds() throws {
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 20)
        editor.timeline.tracks = [Fixtures.videoTrack(clips: [clip])]
        editor.timeline.markers = [TimelineMarker(clipId: clip.id, name: "Note", startFrame: 4)]
        let originalId = try #require(editor.timeline.markers.first?.id)
        let copyId = try #require(editor.duplicateTimeline(editor.activeTimelineId))
        let copy = try #require(editor.timeline(for: copyId))
        let copiedMarker = try #require(copy.markers.first)
        #expect(copiedMarker.id != originalId)
        #expect(copiedMarker.clipId == copy.tracks[0].clips[0].id)
    }
    @Test func markerChangesUndoAsOneAction() throws {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undo.attach(undo)
        let created = try #require(try editor.changeTimelineMarkers(
            creates: [TimelineMarker(
                name: "Audio note",
                startFrame: 12,
                durationFrames: 8,
                color: .init(r: 1, g: 1, b: 0),
                comment: "Lower this"
            )],
            actionName: "Add Marker"
        ).created.first)
        #expect(editor.timeline.markers == [created])
        undo.undo()
        #expect(editor.timeline.markers.isEmpty)
        undo.redo()
        #expect(editor.timeline.markers == [created])
    }
    @Test func clipMarkerProjectsThroughTrimAndSpeed() {
        var clip = Fixtures.clip(mediaRef: "source", start: 100, duration: 20, trimStart: 10, speed: 2)
        clip.trimEndFrame = 10
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        editor.timeline.markers = [TimelineMarker(clipId: clip.id, name: "Clip note", startFrame: 30)]
        #expect(editor.displayedTimelineMarkers().first {
            $0.clipId == clip.id
        }?.startFrame == 110)
        #expect(editor.timelineMarkerSnapFrames() == [110])
        #expect(editor.timelineMarkerSnapFrames(excludingClipIds: [clip.id]).isEmpty)
        #expect(editor.timelineMarkerSnapFrames(
            excludingMarkerIds: [editor.timeline.markers[0].id]
        ).isEmpty)
    }
    @Test func deletingClipRemovesItsMarkerInTheSameUndo() {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 20)
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undo.attach(undo)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        editor.timeline.markers = [TimelineMarker(clipId: clip.id, name: "Note", startFrame: 4)]
        editor.removeClips(ids: [clip.id])
        #expect(editor.timeline.markers.isEmpty)
        undo.undo()
        #expect(editor.timeline.markers.first?.clipId == clip.id)
    }
    @Test func selectedClipCreatesClipMarkerAtPlayhead() {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 20)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        editor.selectedClipIds = [clip.id]
        editor.currentFrame = 10
        #expect(editor.addTimelineMarkerAtSelection()?.clipId == clip.id)
    }
    @Test func marqueeCrossingRulerSelectsTimelineAndClipMarkers() {
        let geometry = TimelineGeometry(pixelsPerFrame: 1, trackHeights: [50])
        let markers = [
            TimelineMarker(id: "timeline", name: "Timeline", startFrame: 10),
            TimelineMarker(id: "clip", clipId: "clip", name: "Clip", startFrame: 20),
        ]
        let selected = TimelineMarkerRenderer.markerIds(
            intersecting: NSRect(x: 0, y: 0, width: 30, height: 100),
            markers: markers, geometry: geometry, rulerMinY: 0,
            clipRect: { _ in NSRect(x: 0, y: geometry.rulerHeight, width: 100, height: 50) }
        )
        #expect(selected == ["timeline", "clip"])
    }
    @Test func durationBarIsNotAMarkerHitTarget() {
        let geometry = TimelineGeometry(pixelsPerFrame: 1, trackHeights: [])
        let marker = TimelineMarker(id: "range", name: "Range", startFrame: 10, durationFrames: 30)
        let selected = TimelineMarkerRenderer.markerIds(
            intersecting: NSRect(x: 20, y: geometry.rulerHeight - 4, width: 5, height: 2),
            markers: [marker], geometry: geometry, rulerMinY: 0,
            clipRect: { _ in nil }
        )
        #expect(selected.isEmpty)
    }
}
