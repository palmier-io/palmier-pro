import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("Nesting — drop flow")
struct NestingTests {

    @Test func nestTimelineCreatesLinkedClipsAndUndoes() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undo.attach(undo)

        var child = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 60)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(mediaType: .audio, start: 0, duration: 60)])
        ])
        child.name = "Intro"
        e.timelines.append(child)
        undo.removeAllActions()

        #expect(e.nestTimeline(child.id, cursor: .newTrackAt(0), atFrame: 30))

        let videoClips = e.timeline.tracks.first { $0.type == .video }?.clips ?? []
        let audioClips = e.timeline.tracks.first { $0.type == .audio }?.clips ?? []
        #expect(videoClips.count == 1)
        #expect(videoClips[0].mediaType == .sequence)
        #expect(videoClips[0].mediaRef == child.id)
        #expect(videoClips[0].startFrame == 30)
        #expect(videoClips[0].durationFrames == 60)
        #expect(audioClips.count == 1)
        #expect(audioClips[0].sourceClipType == .sequence)
        #expect(audioClips[0].linkGroupId == videoClips[0].linkGroupId)
        #expect(e.clipDisplayLabel(for: videoClips[0]) == "Intro")

        undo.undo()
        #expect(e.timeline.tracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test func nestSelectedClipsMovesSelectionIntoNewTimeline() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undo.attach(undo)

        // Two video lanes + audio; selection skips the top-lane clip at 0 and the audio tail.
        e.timeline.tracks = [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "t1", start: 0, duration: 20), Fixtures.clip(id: "t2", start: 40, duration: 20)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v1", start: 30, duration: 60)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", mediaType: .audio, start: 30, duration: 30), Fixtures.clip(id: "a2", mediaType: .audio, start: 100, duration: 10)])
        ]
        let before = e.timeline
        e.selectedClipIds = ["t2", "v1", "a1"]
        undo.removeAllActions()

        e.nestSelectedClips()

        // Child holds the moved clips rebased to the span start (30), lane order preserved.
        let child = e.timelines.first { $0.name == "Nest 1" }
        #expect(child != nil)
        #expect(child?.tracks.map(\.type) == [.video, .video, .audio])
        #expect(child?.tracks[0].clips.map(\.startFrame) == [10])
        #expect(child?.tracks[1].clips.map(\.startFrame) == [0])
        #expect(child?.tracks[2].clips.map(\.startFrame) == [0])
        #expect(child?.totalFrames == 60)

        // Parent: v1's emptied lane pruned; linked carriers span [30, 90); "t1"/"a2" survive.
        let videoLane = e.timeline.tracks.first { $0.type == .video }!
        let audioLane = e.timeline.tracks.first { $0.type == .audio }!
        #expect(e.timeline.tracks.count == 2)
        let v = videoLane.clips.first { $0.sourceClipType == .sequence }
        let a = audioLane.clips.first { $0.sourceClipType == .sequence }
        #expect(v?.startFrame == 30 && v?.durationFrames == 60)
        #expect(a?.mediaType == .audio)
        #expect(v?.linkGroupId != nil && v?.linkGroupId == a?.linkGroupId)
        #expect(videoLane.clips.contains { $0.id == "t1" })
        #expect(audioLane.clips.contains { $0.id == "a2" })
        #expect(e.selectedClipIds == Set([v?.id, a?.id].compactMap { $0 }))

        undo.undo()
        #expect(e.timeline == before)
        #expect(e.timelines.count == 1)
    }

    @Test func nestSelectedClipsKeepsUnselectedClipInsideSpan() {
        let e = EditorViewModel()
        e.timeline.tracks = [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "s1", start: 0, duration: 20),
                Fixtures.clip(id: "mid", start: 30, duration: 20),
                Fixtures.clip(id: "s2", start: 60, duration: 20),
            ])
        ]
        e.selectedClipIds = ["s1", "s2"]

        e.nestSelectedClips()

        // The unselected mid clip survives on its track; the carrier lands on a fresh one.
        let all = e.timeline.tracks.flatMap(\.clips)
        #expect(all.contains { $0.id == "mid" })
        let carrier = all.first { $0.sourceClipType == .sequence }
        #expect(carrier?.startFrame == 0)
        #expect(carrier?.durationFrames == 80)
        #expect(e.timeline.tracks.count == 2)
    }

    @Test func nestSelectedClipsRegeneratesGroupIdsInChild() {
        let e = EditorViewModel()
        var v = Fixtures.clip(id: "v", start: 0, duration: 30)
        v.linkGroupId = "g1"
        var a = Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 30)
        a.linkGroupId = "g1"
        e.timeline.tracks = [Fixtures.videoTrack(clips: [v]), Fixtures.audioTrack(clips: [a])]
        e.selectedClipIds = ["v"]

        e.nestSelectedClips()

        // A partially-nested link group must not span two timelines.
        let child = e.timelines.first { $0.name == "Nest 1" }
        let moved = child?.tracks.flatMap(\.clips).first
        #expect(moved != nil)
        #expect(moved?.linkGroupId != "g1")
        #expect(e.timeline.tracks.flatMap(\.clips).contains { $0.id == "a" && $0.linkGroupId == "g1" })
    }

    @Test func decomposeReplacesNestWithChildClipsInPlace() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undo.attach(undo)

        // Child: two video lanes + one audio lane; the audio clip carries volume 0.8.
        var linked = Fixtures.clip(id: "cv", start: 0, duration: 40)
        linked.linkGroupId = "g1"
        var linkedAudio = Fixtures.clip(id: "ca", mediaType: .audio, start: 0, duration: 40, volume: 0.8)
        linkedAudio.linkGroupId = "g1"
        let child = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "top", start: 10, duration: 20)]),
            Fixtures.videoTrack(clips: [linked]),
            Fixtures.audioTrack(clips: [linkedAudio])
        ])
        e.timelines.append(child)
        #expect(e.nestTimeline(child.id, cursor: .newTrackAt(0), atFrame: 100))
        let nestId = e.timeline.tracks.first { $0.type == .video }!.clips[0].id
        let nestVolume = 0.5
        let carrierIdx = e.timeline.tracks.firstIndex { $0.type == .audio }!
        e.timeline.tracks[carrierIdx].clips[0].volume = nestVolume
        undo.removeAllActions()
        let before = e.timeline

        e.decomposeNest(clipId: nestId)

        let videoTracks = e.timeline.tracks.filter { $0.type == .video }
        let audioTracks = e.timeline.tracks.filter { $0.type == .audio }
        #expect(videoTracks.count == 2)
        #expect(audioTracks.count == 1)
        // Child track order preserved, remapped by the nest's start frame.
        #expect(videoTracks[0].clips.map(\.startFrame) == [110])
        #expect(videoTracks[1].clips.map(\.startFrame) == [100])
        #expect(audioTracks[0].clips.map(\.startFrame) == [100])
        // Fresh ids; child A/V link survives under a remapped group id.
        let v = videoTracks[1].clips[0], a = audioTracks[0].clips[0]
        #expect(v.id != "cv" && a.id != "ca")
        #expect(v.linkGroupId != nil && v.linkGroupId == a.linkGroupId && v.linkGroupId != "g1")
        // Carrier volume folds into the child audio clip; no group look → no toast.
        #expect(abs(a.volume - 0.8 * nestVolume) < 0.0001)
        #expect(e.mediaPanelToast == nil)

        undo.undo()
        #expect(e.timeline == before)
    }

    @Test func composeThenDecomposeRoundTripsToOriginalTracks() {
        // Leftovers on every lane; the moved clips must return to the tracks they left.
        let e = EditorViewModel()
        e.timeline.tracks = [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "capIntro", start: 0, duration: 25), Fixtures.clip(id: "cap", start: 30, duration: 40)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "vIntro", start: 0, duration: 25), Fixtures.clip(id: "v", start: 30, duration: 60)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "aIntro", mediaType: .audio, start: 0, duration: 25), Fixtures.clip(id: "a", mediaType: .audio, start: 30, duration: 60)])
        ]
        e.selectedClipIds = ["cap", "v", "a"]

        e.nestSelectedClips()
        let carrier = e.timeline.tracks.flatMap(\.clips).first { $0.mediaType == .sequence }!
        e.decomposeNest(clipId: carrier.id)

        // Same three tracks, no extras, each lane's content back beside its leftover.
        #expect(e.timeline.tracks.count == 3)
        #expect(e.timeline.tracks[0].clips.map(\.startFrame) == [0, 30])
        #expect(e.timeline.tracks[1].clips.map(\.startFrame) == [0, 30])
        #expect(e.timeline.tracks[2].clips.map(\.startFrame) == [0, 30])
        #expect(e.timeline.tracks[1].clips[1].durationFrames == 60)
        #expect(!e.timeline.tracks.contains { $0.clips.isEmpty })
    }

    @Test func decomposeWarnsWhenGroupLookIsDiscarded() {
        let e = EditorViewModel()
        let child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])])
        e.timelines.append(child)
        #expect(e.nestTimeline(child.id, cursor: .newTrackAt(0), atFrame: 0))
        let nestId = e.timeline.tracks[0].clips[0].id
        e.timeline.tracks[0].clips[0].crop = Crop(left: 0.2, top: 0, right: 0, bottom: 0)

        e.decomposeNest(clipId: nestId)
        #expect(e.mediaPanelToast != nil)
        #expect(!e.timeline.tracks[0].clips.contains { $0.sourceClipType == .sequence })
    }

    @Test func nestRejectsCyclesAndEmptyTimelines() {
        let e = EditorViewModel()

        // Empty child rejected.
        let empty = Fixtures.timeline()
        e.timelines.append(empty)
        #expect(!e.nestTimeline(empty.id, cursor: .newTrackAt(0), atFrame: 0))

        // Self-nesting rejected.
        e.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])]
        #expect(!e.nestTimeline(e.activeTimelineId, cursor: .newTrackAt(0), atFrame: 0))

        // Transitive cycle rejected: A nests B; nesting A into B would loop.
        let b = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])])
        e.timelines.append(b)
        let aId = e.activeTimelineId
        #expect(e.nestTimeline(b.id, cursor: .newTrackAt(0), atFrame: 0))   // A nests B
        e.activateTimeline(b.id)
        #expect(!e.nestTimeline(aId, cursor: .newTrackAt(0), atFrame: 0))   // B can't nest A
    }
}
