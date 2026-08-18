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

    @Test func multiTrackRippleDeleteDoesNotOverShiftMarkers() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "v1", start: 0, duration: 50),
                Fixtures.clip(id: "v2", start: 200, duration: 100),
            ]),
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: "a1", mediaType: .audio, start: 200, duration: 50),
                Fixtures.clip(id: "a2", mediaType: .audio, start: 300, duration: 50),
            ]),
        ])
        e.rippleTimelineMarkers = true
        e.timeline.markers = [
            TimelineMarker(id: "onPicture", name: "On picture", startFrame: 220),
            TimelineMarker(id: "after", name: "After", startFrame: 300),
        ]
        e.selectedClipIds = ["v1", "a1"]
        e.rippleDeleteSelectedClips()
        #expect(e.timeline.markers.map(\.id) == ["onPicture", "after"])
        #expect(e.timeline.markers.map(\.startFrame) == [170, 250])
    }

    @Test func multiTrackRippleDeleteDoesNotFollowACollapsedHole() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "v1", start: 0, duration: 50),
                Fixtures.clip(id: "v2", start: 200, duration: 100),
            ]),
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: "a1", mediaType: .audio, start: 100, duration: 150),
                Fixtures.clip(id: "a2", mediaType: .audio, start: 300, duration: 50),
            ]),
        ])
        e.rippleTimelineMarkers = true
        e.timeline.markers = [
            TimelineMarker(id: "onPicture", name: "On picture", startFrame: 220),
        ]
        e.selectedClipIds = ["v1", "a1"]
        e.rippleDeleteSelectedClips()
        #expect(e.timeline.markers.map(\.startFrame) == [170])
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
