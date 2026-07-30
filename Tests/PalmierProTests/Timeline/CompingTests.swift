import Foundation
import Testing
@testable import PalmierPro

@Suite("Comping — assemble takes onto a Comp track")
struct CompingTests {

    @Test("compSegment trims a clip to the window and rebases its trim")
    func compSegmentTrimsToWindow() {
        let clip = Fixtures.clip(id: "x", start: 10, duration: 100, trimStart: 5)
        let seg = EditorViewModel.compSegment(of: clip, in: 40..<70)
        #expect(seg?.startFrame == 40)
        #expect(seg?.durationFrames == 30)
        #expect(seg?.trimStartFrame == 35)
        #expect(seg?.id != "x")
        #expect(seg?.linkGroupId == nil)
    }

    @Test("compSegment returns nil when the clip does not overlap the window")
    func compSegmentNilWhenDisjoint() {
        let clip = Fixtures.clip(id: "x", start: 0, duration: 10)
        #expect(EditorViewModel.compSegment(of: clip, in: 20..<30) == nil)
    }

    @Test("Legacy project JSON without an isComp key still decodes")
    func decodesLegacyTrackWithoutIsComp() throws {
        let track = try JSONDecoder().decode(Track.self, from: Data(#"{"type":"video","clips":[]}"#.utf8))
        #expect(track.isComp == false)
    }

    @MainActor
    @Test("Comp assembles the selected take over the range onto a new top Comp track, leaving sources intact")
    func compAssemblesSelectedTakeOntoTopCompTrack() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "v0", clips: [Fixtures.clip(id: "c0", mediaRef: "takeA", start: 0, duration: 100)]),
            Fixtures.videoTrack(id: "v1", clips: [Fixtures.clip(id: "c1", mediaRef: "takeB", start: 0, duration: 100)]),
        ])
        e.setTimelineRange(startFrame: 30, endFrame: 60)
        e.selectedClipIds = ["c1"]
        #expect(e.canCompSelection == true)

        e.compSelectedRangeFromSelectedTake()

        #expect(e.timeline.tracks[0].isComp == true)
        let compClips = e.timeline.tracks[0].clips
        #expect(compClips.count == 1)
        #expect(compClips.first?.startFrame == 30)
        #expect(compClips.first?.durationFrames == 30)
        #expect(compClips.first?.mediaRef == "takeB")
        // Source takes are untouched (now shifted down by the inserted Comp track).
        #expect(e.timeline.tracks[1].clips.map(\.id) == ["c0"])
        #expect(e.timeline.tracks[2].clips.map(\.id) == ["c1"])
    }

    @MainActor
    @Test("Re-comping the same range overwrites the comp region rather than stacking")
    func recompingOverwritesRegion() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "v1", clips: [Fixtures.clip(id: "c1", mediaRef: "takeB", start: 0, duration: 100)]),
        ])
        e.setTimelineRange(startFrame: 30, endFrame: 60)
        e.selectedClipIds = ["c1"]
        e.compSelectedRangeFromSelectedTake()
        e.compSelectedRangeFromSelectedTake()

        let compClips = e.timeline.tracks[0].clips
        #expect(compClips.count == 1)
        #expect(compClips.first?.startFrame == 30)
        #expect(compClips.first?.durationFrames == 30)
    }

    @MainActor
    @Test("Comp requires both a range and a selected take")
    func compRequiresRangeAndTake() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "v0", clips: [Fixtures.clip(id: "c0", start: 0, duration: 50)]),
        ])
        #expect(e.canCompSelection == false)
        e.selectedClipIds = ["c0"]
        #expect(e.canCompSelection == false)
        e.setTimelineRange(startFrame: 0, endFrame: 20)
        #expect(e.canCompSelection == true)
    }
}
