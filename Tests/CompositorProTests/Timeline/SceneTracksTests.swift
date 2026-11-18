import Foundation
import Testing
@testable import CompositorPro

@Suite("Scene tracks")
struct SceneTracksTests {
    private func timeline() -> Timeline {
        Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "main-clip", start: 0, duration: 60)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "overlay-clip", start: 10, duration: 30)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "audio-clip", mediaType: .audio, start: 0, duration: 60)]),
        ])
    }

    @Test func adapterSplitsMainOverlaysAndAudio() throws {
        let source = timeline()
        let scene = try SceneTracks(timeline: source)
        #expect(scene.main.clips.map(\.id) == ["main-clip"])
        #expect(scene.overlays.count == 1)
        #expect(scene.overlays.first?.clips.map(\.id) == ["overlay-clip"])
        #expect(scene.audio.count == 1)
        #expect(scene.tracks.map(\.id) == source.tracks.map(\.id))
    }

    @Test func timelinesWithoutAVisualTrackAreRejected() {
        let audioOnly = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [])])
        #expect(throws: TrackError.self) { try SceneTracks(timeline: audioOnly) }
    }

    @Test func wrongKindInsertionIsRefused() throws {
        var scene = try SceneTracks(timeline: timeline())
        let audioClip = Fixtures.clip(mediaRef: "voice", mediaType: .audio, start: 90, duration: 30)
        #expect(throws: TrackError.self) { try scene.insert(audioClip, into: scene.main.id) }

        let videoClip = Fixtures.clip(mediaRef: "b-roll", mediaType: .video, start: 0, duration: 30)
        let audioTrackId = try #require(scene.audio.first?.id)
        #expect(throws: TrackError.self) { try scene.insert(videoClip, into: audioTrackId) }
    }

    @Test func matchingKindsInsertInPlace() throws {
        var scene = try SceneTracks(timeline: timeline())
        let overlayId = try #require(scene.overlays.first?.id)
        let overlayClip = Fixtures.clip(mediaRef: "insert", mediaType: .video, start: 60, duration: 30)
        try scene.insert(overlayClip, into: overlayId)
        #expect(scene.overlays.first?.clips.count == 2)

        let audioClip = Fixtures.clip(mediaRef: "voice", mediaType: .audio, start: 60, duration: 30)
        let audioTrackId = try #require(scene.audio.first?.id)
        try scene.insert(audioClip, into: audioTrackId)
        #expect(scene.audio.first?.clips.count == 2)
    }

    @Test func mainTrackStaysSingleton() throws {
        var scene = try SceneTracks(timeline: timeline())
        #expect(throws: TrackError.self) { try scene.addOverlay(scene.main) }

        let audioTrack = Fixtures.audioTrack(clips: [])
        #expect(throws: TrackError.self) { try scene.addOverlay(audioTrack) }

        let overlay = Fixtures.videoTrack(clips: [])
        try scene.addOverlay(overlay)
        #expect(scene.overlays.count == 2)
    }

    @Test func explicitInitValidatesEveryTrackKind() throws {
        let video = Fixtures.videoTrack(clips: [])
        let audio = Fixtures.audioTrack(clips: [])
        #expect(throws: TrackError.self) { try SceneTracks(main: audio) }
        #expect(throws: TrackError.self) { try SceneTracks(main: video, overlays: [audio]) }
        #expect(throws: TrackError.self) { try SceneTracks(main: video, audio: [video]) }
        let scene = try SceneTracks(main: video, overlays: [Fixtures.videoTrack(clips: [])], audio: [audio])
        #expect(scene.tracks.count == 3)
    }
}
