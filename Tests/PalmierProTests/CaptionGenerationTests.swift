import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

private func textSpec(start: Int, duration: Int, content: String) -> EditorViewModel.TextClipSpec {
    EditorViewModel.TextClipSpec(
        trackIndex: 0, startFrame: start, durationFrames: duration,
        content: content, style: TextStyle(), transform: nil
    )
}

@MainActor
private func mediaAsset(_ id: String, hasAudio: Bool = true) -> MediaAsset {
    let asset = MediaAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id).mov"), type: .video, name: id, duration: 3)
    asset.hasAudio = hasAudio
    return asset
}

@MainActor
@Suite struct CaptionPlacementTests {
    @Test func textClipsStayOnInsertedTrackWhenAClipIsOverwritten() {
        let e = editor([Fixtures.videoTrack(label: "Video", clips: [Fixtures.clip(start: 0, duration: 300)])])
        e.timeline.tracks.insert(Track(type: .video, label: "Captions"), at: 0)

        // spec b (same start, longer) fully covers spec a -> a is removed mid-placement.
        let ids = e.placeTextClips([
            textSpec(start: 0, duration: 20, content: "a"),
            textSpec(start: 0, duration: 100, content: "b"),
            textSpec(start: 120, duration: 30, content: "c"),
        ])

        #expect(!ids.isEmpty)
        #expect(e.timeline.tracks.count == 2)
        // Captions track survived and holds only text clips.
        #expect(e.timeline.tracks[0].label == "Captions")
        #expect(e.timeline.tracks[0].clips.allSatisfy { $0.mediaType == .text })
        #expect(!e.timeline.tracks[0].clips.isEmpty)
        // Video track is untouched.
        #expect(e.timeline.tracks[1].label == "Video")
        #expect(e.timeline.tracks[1].clips.count == 1)
        #expect(e.timeline.tracks[1].clips[0].mediaType == .video)
    }

    @Test func textClipPlacementNeverPrunesOtherEmptyTracks() {
        let e = editor([
            Fixtures.videoTrack(label: "Captions"),                       // empty target
            Fixtures.videoTrack(label: "Video", clips: [Fixtures.clip(start: 0, duration: 100)]),
        ])
        _ = e.placeTextClips([textSpec(start: 0, duration: 50, content: "hi")])
        #expect(e.timeline.tracks.count == 2)
        #expect(e.timeline.tracks[0].clips.count == 1)
    }
}

@MainActor
@Suite struct CaptionTargetTests {
    @Test func linkedAndTrackTargetsChooseAudioSide() {
        let groupId = "linked-1"
        var video = Fixtures.clip(id: "video", mediaRef: "media-1", mediaType: .video, start: 0, duration: 100)
        var audio = Fixtures.clip(id: "audio", mediaRef: "media-1", mediaType: .audio, start: 0, duration: 100)
        let voice = Fixtures.clip(id: "voice", mediaRef: "voice-media", mediaType: .audio, start: 120, duration: 100)
        let music = Fixtures.clip(id: "music", mediaRef: "music-media", mediaType: .audio, start: 240, duration: 100)
        video.linkGroupId = groupId
        audio.linkGroupId = groupId
        let e = editor([
            Fixtures.videoTrack(id: "video-track", clips: [video]),
            Fixtures.audioTrack(id: "audio-track", clips: [audio]),
            Fixtures.audioTrack(id: "voice-track", label: "Voiceover", clips: [voice]),
            Fixtures.audioTrack(id: "music-track", label: "Music", clips: [music]),
        ])

        #expect(e.captionTargets(ids: []).map(\.id) == ["audio", "voice", "music"])
        #expect(e.captionTargets(ids: ["video"]).map(\.id) == ["video"])
        #expect(e.captionTargets(trackIds: ["voice-track"]).map(\.id) == ["voice"])
        #expect(e.captionTargets(trackIds: ["video-track", "audio-track"]).map(\.id) == ["audio"])
        #expect(e.captionTargets(trackIds: ["video-track"]).isEmpty)
        #expect(e.captionTargets(trackIds: ["audio-track"]).map(\.id) == ["audio"])
    }

    @Test func mediaMetadataFiltersCaptionSources() {
        let silent = Fixtures.clip(id: "silent", mediaRef: "silent-media", mediaType: .video, start: 0, duration: 100)
        let linkedAudio = Fixtures.clip(id: "audio", mediaRef: "video-media", mediaType: .audio, start: 120, duration: 100)
        let e = editor([
            Fixtures.videoTrack(clips: [silent]),
            Fixtures.audioTrack(clips: [linkedAudio]),
        ])
        e.mediaAssets.append(contentsOf: [mediaAsset("silent-media", hasAudio: false), mediaAsset("video-media")])

        #expect(e.captionTargets(ids: []).map(\.id) == ["audio"])
        #expect(e.captionUsesVideoAudioExtraction(for: linkedAudio))
    }
}

@Suite struct CaptionCaseTests {
    @Test func transformsText() {
        #expect(EditorViewModel.CaptionCase.auto.apply("Hello World.") == "Hello World.")
        #expect(EditorViewModel.CaptionCase.upper.apply("Hello World.") == "HELLO WORLD.")
        #expect(EditorViewModel.CaptionCase.lower.apply("Hello World.") == "hello world.")
    }
}

@Suite struct TranscriptionAudioFormatTests {
    @Test func writesInt16InterleavedBufferWithoutParamError() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-fmt-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        try file.write(from: buffer)   // threw -50 before the fix

        let readback = try AVAudioFile(forReading: url)
        #expect(readback.length > 0)
    }
}
