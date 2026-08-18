import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(markers: [TimelineMarker], ripple: Bool) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: [
        Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ])
    ])
    e.timeline.markers = markers
    e.rippleTimelineMarkers = ripple
    return e
}

@Suite("EditorViewModel — ripple timeline markers")
@MainActor
struct TimelineMarkerRippleTests {
    @Test func rippleDeleteShiftsAndRemovesMarkersWhenEnabled() {
        let before = TimelineMarker(id: "before", name: "Before", startFrame: 10)
        let inside = TimelineMarker(id: "inside", name: "Inside", startFrame: 45)
        let after = TimelineMarker(id: "after", name: "After", startFrame: 80)
        let e = editor(markers: [before, inside, after], ripple: true)
        let outcome = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok = outcome else { Issue.record("expected .ok"); return }
        #expect(e.timeline.markers.map(\.id) == ["before", "after"])
        #expect(e.timeline.markers.map(\.startFrame) == [10, 70])
    }

    @Test func rippleDeleteLeavesMarkersWhenDisabled() {
        let inside = TimelineMarker(id: "inside", name: "Inside", startFrame: 45)
        let after = TimelineMarker(id: "after", name: "After", startFrame: 80)
        let e = editor(markers: [inside, after], ripple: false)
        let outcome = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok = outcome else { Issue.record("expected .ok"); return }
        #expect(e.timeline.markers.map(\.startFrame) == [45, 80])
    }

    @Test func markerRippleUndoesWithTheEdit() {
        let after = TimelineMarker(id: "after", name: "After", startFrame: 80)
        let e = editor(markers: [after], ripple: true)
        let undo = UndoManager()
        e.undo.attach(undo)
        let outcome = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok = outcome else { Issue.record("expected .ok"); return }
        #expect(e.timeline.markers[0].startFrame == 70)
        undo.undo()
        #expect(e.timeline.markers[0].startFrame == 80)
        undo.redo()
        #expect(e.timeline.markers[0].startFrame == 70)
    }
}
