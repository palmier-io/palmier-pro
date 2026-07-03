import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("Nesting — drop flow")
struct NestingTests {

    @Test func nestTimelineCreatesLinkedClipsAndUndoes() {
        let e = EditorViewModel()
        let undo = UndoManager()
        e.undoManager = undo

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
