import Foundation
import Testing
@testable import PalmierPro

@Suite("Timeline markers")
@MainActor
struct TimelineMarkerTests {
    @Test func markersPersistWithoutChangingContentDuration() throws {
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])])
        timeline.markers = [TimelineMarker(name: "Review", startFrame: 40, durationFrames: 10, color: .init(r: 1, g: 0, b: 0), comment: "Tighten", status: .review)]
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
    @Test func markersWithoutStatusDecodeAsOpen() throws {
        var timeline = Fixtures.timeline()
        timeline.markers = [
            TimelineMarker(name: "Existing marker", startFrame: 12, status: .review)
        ]
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(timeline)
            ) as? [String: Any]
        )
        var markers = try #require(object["markers"] as? [[String: Any]])
        markers[0].removeValue(forKey: "status")
        object["markers"] = markers

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)

        #expect(decoded.markers.count == 1)
        #expect(decoded.markers[0].status == .open)
    }
    @Test func duplicateTimelineFreshensMarkerIds() throws {
        let editor = EditorViewModel()
        editor.timeline.markers = [TimelineMarker(name: "Note", startFrame: 4)]
        let originalId = try #require(editor.timeline.markers.first?.id)
        let copyId = try #require(editor.duplicateTimeline(editor.activeTimelineId))
        let copy = try #require(editor.timeline(for: copyId))
        let copiedMarker = try #require(copy.markers.first)
        #expect(copiedMarker.id != originalId)
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
        #expect(editor.timelineMarkerSnapFrames() == [12, 20])
        #expect(editor.timelineMarkerSnapFrames(
            excludingMarkerIds: [created.id]
        ).isEmpty)
    }
    @Test func markerStatusChangesUndo() throws {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undo.attach(undo)
        editor.timeline.markers = [TimelineMarker(id: "marker", name: "Review", startFrame: 12)]
        var marker = editor.timeline.markers[0]
        marker.status = .review
        _ = try editor.changeTimelineMarkers(
            updates: [marker],
            actionName: "Change Marker Status"
        )
        #expect(editor.timeline.markers[0].status == .review)
        undo.undo()
        #expect(editor.timeline.markers[0].status == .open)
    }
    @Test func committingMarkerChangeClearsItsPreview() throws {
        let editor = EditorViewModel()
        let marker = TimelineMarker(id: "marker", name: "Review", startFrame: 12)
        editor.timeline.markers = [marker]
        var preview = marker
        preview.startFrame = 20
        editor.timelineMarkerPreview = preview

        _ = try editor.changeTimelineMarkers(
            updates: [preview],
            actionName: "Move Marker"
        )

        #expect(editor.timeline.markers == [preview])
        #expect(editor.timelineMarkerPreview == nil)
    }
    @Test func defaultMarkerNamesUseNextNumber() {
        let editor = EditorViewModel()
        editor.selectedClipIds = ["clip"]
        editor.currentFrame = 10
        let first = editor.addTimelineMarkerAtSelection()
        editor.currentFrame = 11
        let second = editor.addTimelineMarkerAtSelection()
        #expect((first?.startFrame, first?.name) == (10, L10n.string("Marker 1")))
        #expect(second?.name == L10n.string("Marker 2"))
    }
    @Test func marqueeCrossingRulerSelectsMarkers() {
        let geometry = TimelineGeometry(pixelsPerFrame: 1, trackHeights: [50])
        let markers = [
            TimelineMarker(id: "first", name: "First", startFrame: 10),
            TimelineMarker(id: "second", name: "Second", startFrame: 20),
        ]
        let selected = TimelineMarkerRenderer.markerIds(
            intersecting: NSRect(x: 0, y: 0, width: 30, height: 100),
            markers: markers, geometry: geometry, rulerMinY: 0
        )
        #expect(selected == ["first", "second"])
    }
    @Test func durationBarIsNotAMarkerHitTarget() {
        let geometry = TimelineGeometry(pixelsPerFrame: 1, trackHeights: [])
        let marker = TimelineMarker(id: "range", name: "Range", startFrame: 10, durationFrames: 30)
        let selected = TimelineMarkerRenderer.markerIds(
            intersecting: NSRect(x: 20, y: 0, width: 5, height: 2),
            markers: [marker], geometry: geometry, rulerMinY: 0
        )
        #expect(selected.isEmpty)
    }

    @Test func markerFlagSitsAtTopOfRuler() {
        let geometry = TimelineGeometry(pixelsPerFrame: 1, trackHeights: [])
        let marker = TimelineMarker(id: "mark", name: "Mark", startFrame: 10)
        #expect(
            TimelineMarkerRenderer.marker(
                at: NSPoint(x: 10, y: 2),
                markers: [marker],
                geometry: geometry,
                rulerMinY: 0
            )?.id == "mark"
        )
        #expect(
            TimelineMarkerRenderer.marker(
                at: NSPoint(x: 10, y: geometry.rulerHeight - 2),
                markers: [marker],
                geometry: geometry,
                rulerMinY: 0
            ) == nil
        )
    }
}
