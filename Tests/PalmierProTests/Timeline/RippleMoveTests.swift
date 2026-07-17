import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@MainActor
private func clips(_ e: EditorViewModel, track: Int) -> [(id: String, start: Int, duration: Int)] {
    e.timeline.tracks[track].clips.map { ($0.id, $0.startFrame, $0.durationFrames) }
}

@Suite("EditorViewModel - ripple move")
@MainActor
struct RippleMoveTests {

    @Test func moveLaterOnSameTrackSplitsStraddlerAndPushesDownstream() {
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 10),
            Fixtures.clip(id: "b", start: 10, duration: 10),
            Fixtures.clip(id: "c", start: 20, duration: 10),
        ])])

        e.rippleMoveClips([(clipId: "a", toTrack: 0, toFrame: 12)])

        let result = clips(e, track: 0)
        #expect(result.map(\.start) == [10, 12, 22, 30])
        #expect(result[0].id == "b")
        #expect(result[0].duration == 2)
        #expect(result[1].id == "a")
        #expect(result[2].duration == 8)
        #expect(result[3].id == "c")
    }

    @Test func moveEarlierOnSameTrackInsertsWithoutOverlap() {
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 10),
            Fixtures.clip(id: "b", start: 20, duration: 10),
        ])])

        e.rippleMoveClips([(clipId: "b", toTrack: 0, toFrame: 5)])

        let result = clips(e, track: 0)
        #expect(result.map(\.start) == [0, 5, 15])
        #expect(result[0].duration == 5)
        #expect(result[1].id == "b")
        #expect(result[2].duration == 5)
        for i in 1..<result.count {
            #expect(result[i].start >= result[i - 1].start + result[i - 1].duration)
        }
    }

    @Test func movedClipLandsExactlyAtDropFrame() {
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 10),
            Fixtures.clip(id: "b", start: 10, duration: 10),
        ])])

        e.rippleMoveClips([(clipId: "a", toTrack: 0, toFrame: 3)])

        let result = clips(e, track: 0)
        #expect(result.first { $0.id == "a" }?.start == 3)
        #expect(result.first { $0.id == "b" }?.start == 20)
    }

    @Test func moveBeyondFollowerLeavesSourceGap() {
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 10),
            Fixtures.clip(id: "b", start: 30, duration: 10),
        ])])

        e.rippleMoveClips([(clipId: "a", toTrack: 0, toFrame: 45)])

        let result = clips(e, track: 0)
        #expect(result.first { $0.id == "b" }?.start == 30)
        #expect(result.first { $0.id == "a" }?.start == 45)
    }

    @Test func syncLockedTrackPushesWithDestination() {
        var video = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "v1", start: 0, duration: 10),
            Fixtures.clip(id: "v2", start: 50, duration: 10),
        ])
        video.syncLocked = false
        var locked = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "s1", mediaType: .audio, start: 30, duration: 10),
        ])
        locked.syncLocked = true
        let e = editor([video, locked])

        e.rippleMoveClips([(clipId: "v1", toTrack: 0, toFrame: 20)])

        #expect(clips(e, track: 0).first { $0.id == "v1" }?.start == 20)
        #expect(clips(e, track: 0).first { $0.id == "v2" }?.start == 60)
        #expect(clips(e, track: 1).first { $0.id == "s1" }?.start == 40)
    }

    @Test func unlockedOtherTrackStaysPut() {
        var video = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "v1", start: 0, duration: 10),
            Fixtures.clip(id: "v2", start: 50, duration: 10),
        ])
        video.syncLocked = false
        var other = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "o1", mediaType: .audio, start: 30, duration: 10),
        ])
        other.syncLocked = false
        let e = editor([video, other])

        e.rippleMoveClips([(clipId: "v1", toTrack: 0, toFrame: 20)])

        #expect(clips(e, track: 1).first { $0.id == "o1" }?.start == 30)
    }

    @Test func crossTrackMovePushesDestinationOnly() {
        var t0 = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "mover", start: 0, duration: 10),
            Fixtures.clip(id: "tail", start: 10, duration: 10),
        ])
        t0.syncLocked = false
        var t1 = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "d1", start: 20, duration: 10),
        ])
        t1.syncLocked = false
        let e = editor([t0, t1])

        e.rippleMoveClips([(clipId: "mover", toTrack: 1, toFrame: 20)])

        let source = e.timeline.tracks.first { $0.clips.contains { $0.id == "tail" } }!
        let dest = e.timeline.tracks.first { $0.clips.contains { $0.id == "d1" } }!
        #expect(source.clips.first { $0.id == "tail" }?.startFrame == 10)
        #expect(dest.clips.first { $0.id == "mover" }?.startFrame == 20)
        #expect(dest.clips.first { $0.id == "d1" }?.startFrame == 30)
    }

    @Test func linkedPartnerOfSplitStraddlerRidesThePush() {
        var v = Fixtures.clip(id: "v", start: 20, duration: 20)
        v.linkGroupId = "g"
        var a = Fixtures.clip(id: "a", mediaType: .audio, start: 20, duration: 20)
        a.linkGroupId = "g"
        var video = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "mover", start: 0, duration: 10),
            v,
        ])
        video.syncLocked = false
        var audio = Fixtures.audioTrack(clips: [a])
        audio.syncLocked = false
        let e = editor([video, audio])

        e.rippleMoveClips([(clipId: "mover", toTrack: 0, toFrame: 30)])

        let videoStarts = clips(e, track: 0).map(\.start).sorted()
        let audioStarts = clips(e, track: 1).map(\.start).sorted()
        #expect(videoStarts == [20, 30, 40])
        #expect(audioStarts == [20, 40])
    }

    @Test func rippleMoveIsUndoable() {
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 10),
            Fixtures.clip(id: "b", start: 10, duration: 10),
        ])])
        let undo = UndoManager()
        e.undo.attach(undo)

        e.rippleMoveClips([(clipId: "a", toTrack: 0, toFrame: 15)])
        #expect(clips(e, track: 0).first { $0.id == "a" }?.start == 15)

        undo.undo()
        let result = clips(e, track: 0)
        #expect(result.first { $0.id == "a" }?.start == 0)
        #expect(result.first { $0.id == "b" }?.start == 10)
    }
}
