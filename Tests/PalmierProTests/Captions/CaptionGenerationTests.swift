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
    @Test func bulkNonOverwritingPlacementMutatesTimelineOnce() {
        let e = editor([Fixtures.videoTrack()])
        let specs = (0..<1_000).map {
            textSpec(start: $0 * 30, duration: 30, content: "caption \($0)")
        }
        let revision = e.timelineRenderRevision

        let ids = e.placeTextClips(specs, clearExistingRegions: false, refreshVisuals: false)

        #expect(ids.count == specs.count)
        #expect(e.timelineRenderRevision == revision + 1)
        #expect(e.timeline.tracks[0].clips.map(\.startFrame) == specs.map(\.startFrame))
    }

    @Test func textClipsStayOnInsertedTrackWhenAClipIsOverwritten() {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 300)])])
        e.timeline.tracks.insert(Track(type: .video), at: 0)

        // spec b (same start, longer) fully covers spec a -> a is removed mid-placement.
        let ids = e.placeTextClips([
            textSpec(start: 0, duration: 20, content: "a"),
            textSpec(start: 0, duration: 100, content: "b"),
            textSpec(start: 120, duration: 30, content: "c"),
        ])

        #expect(!ids.isEmpty)
        #expect(e.timeline.tracks.count == 2)
        // Captions track survived and holds only text clips.
        #expect(e.timeline.tracks[0].clips.allSatisfy { $0.mediaType == .text })
        #expect(!e.timeline.tracks[0].clips.isEmpty)
        // Video track is untouched.
        #expect(e.timeline.tracks[1].clips.count == 1)
        #expect(e.timeline.tracks[1].clips[0].mediaType == .video)
    }

    @Test func textClipPlacementNeverPrunesOtherEmptyTracks() {
        let e = editor([
            Fixtures.videoTrack(),                       // empty target
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 100)]),
        ])
        _ = e.placeTextClips([textSpec(start: 0, duration: 50, content: "hi")])
        #expect(e.timeline.tracks.count == 2)
        #expect(e.timeline.tracks[0].clips.count == 1)
    }
}

@Suite struct CaptionSpecBuilderTests {
    private func gapTarget(
        id: String,
        startFrame: Int,
        durationFrames: Int,
        hasWordTiming: Bool = true
    ) -> CaptionSpecBuilder.Target {
        let clip = Fixtures.clip(
            id: id,
            mediaRef: "media-\(id)",
            mediaType: .audio,
            start: startFrame,
            duration: durationFrames
        )
        let result = TranscriptionResult(
            text: id,
            language: "en",
            words: hasWordTiming ? [TranscriptionWord(text: id, start: 0, end: 0.1)] : [],
            segments: [TranscriptionSegment(text: id, start: 0, end: 0.2)]
        )
        return CaptionSpecBuilder.Target(
            clip: clip,
            result: result
        )
    }

    private func input(
        targets: [CaptionSpecBuilder.Target],
        maximumGapSeconds: Double = CaptionGapSettings.default.maximumGapSeconds,
        animation: TextAnimation? = nil
    ) -> CaptionSpecBuilder.Input {
        CaptionSpecBuilder.Input(
            targets: targets,
            fps: 30,
            canvasWidth: 1920,
            canvasHeight: 1080,
            style: TextStyle(),
            center: CGPoint(x: 0.5, y: 0.8),
            textCase: .auto,
            maxWords: nil,
            gapSettings: CaptionGapSettings(maximumGapSeconds: maximumGapSeconds) ?? .default,
            animation: animation
        )
    }

    @Test func buildsCaptionSpecsFromImmutableInput() async throws {
        let clip = Fixtures.clip(
            id: "source",
            mediaRef: "media",
            mediaType: .audio,
            start: 0,
            duration: 300
        )
        let result = TranscriptionResult(
            text: "hello world",
            language: "en",
            words: [
                TranscriptionWord(text: "hello", start: 1, end: 1.4),
                TranscriptionWord(text: "world", start: 1.5, end: 2),
            ],
            segments: []
        )
        let input = CaptionSpecBuilder.Input(
            targets: [.init(clip: clip, result: result)],
            fps: 30,
            canvasWidth: 1920,
            canvasHeight: 1080,
            style: TextStyle(),
            center: CGPoint(x: 0.5, y: 0.8),
            textCase: .upper,
            maxWords: nil,
            gapSettings: .default,
            animation: nil
        )

        let specs = try await CaptionSpecBuilder.build(input)
        let spec = try #require(specs.first)

        #expect(specs.count == 1)
        #expect(spec.content == "HELLO WORLD")
        #expect(spec.startFrame == 30)
        #expect(spec.durationFrames == 30)
        #expect(spec.transform != nil)
        #expect(spec.words?.map(\.text) == ["hello", "world"])
    }

    @Test(arguments: [
        (6, 0.25, 27),
        (7, 0.25, 28),
        (8, 0.25, 21),
        (6, 0.0, 21),
    ])
    func closesOnlyGapsWithinTheFrameRoundedThreshold(
        gapFrames: Int,
        maximumGapSeconds: Double,
        expectedFirstDuration: Int
    ) async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(
                    id: "two",
                    startFrame: 21 + gapFrames,
                    durationFrames: 30
                ),
            ],
            maximumGapSeconds: maximumGapSeconds
        ))

        #expect(specs.map(\.startFrame) == [0, 21 + gapFrames])
        #expect(specs.map(\.durationFrames) == [expectedFirstDuration, 21])
        #expect(specs[0].words == [WordTiming(text: "one", startFrame: 0, endFrame: 3)])
    }

    @Test(arguments: [
        TextAnimation.Preset.fadeIn,
        .popIn,
        .slideUp,
        .typewriter,
        .wordReveal,
        .wordSlide,
        .wordPop,
        .wordCycle,
    ])
    func holdsPreviousCaptionThroughTransparentAnimatedEntry(
        preset: TextAnimation.Preset
    ) async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(id: "two", startFrame: 27, durationFrames: 30),
            ],
            animation: TextAnimation(preset: preset)
        ))

        #expect(specs.map(\.durationFrames) == [28, 21])
        #expect(specs[0].words?.last?.endFrame == (preset == .wordCycle ? 28 : 3))
    }

    @Test func oneFrameAnimatedCaptionOwnsTheFollowingGap() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(id: "two", startFrame: 27, durationFrames: 1, hasWordTiming: false),
                gapTarget(id: "three", startFrame: 33, durationFrames: 30),
            ],
            animation: TextAnimation(preset: .fadeIn)
        ))

        #expect(specs.map(\.durationFrames) == [28, 7, 21])
    }

    @Test func leavesOverlapsUnchanged() async throws {
        let overlapping = try await CaptionSpecBuilder.build(input(targets: [
            gapTarget(id: "one", startFrame: 0, durationFrames: 21),
            gapTarget(id: "two", startFrame: 20, durationFrames: 30),
        ]))

        #expect(overlapping.map(\.durationFrames) == [21, 21])
    }

    @Test func closesGapFromTheClipProvidingLatestCoverage() async throws {
        let specs = try await CaptionSpecBuilder.build(input(targets: [
            gapTarget(id: "outer", startFrame: 0, durationFrames: 40),
            gapTarget(id: "nested", startFrame: 10, durationFrames: 5),
            gapTarget(id: "next", startFrame: 26, durationFrames: 30),
        ]))

        #expect(specs.map(\.durationFrames) == [26, 5, 21])
    }

    @Test func captionGapSettingsValidateAndRoundDownToFrames() {
        #expect(CaptionGapSettings.default.maximumGapFrames(fps: 30) == 7)
        #expect(CaptionGapSettings(maximumGapSeconds: 0)?.maximumGapFrames(fps: 30) == 0)
        #expect(CaptionGapSettings(maximumGapSeconds: -0.1) == nil)
        #expect(CaptionGapSettings(maximumGapSeconds: 2.1) == nil)
        #expect(CaptionGapSettings(maximumGapSeconds: .infinity) == nil)
    }
}

@MainActor
@Suite struct CaptionTargetTests {
    @Test func preparationTracksTimelineValueInsteadOfRenderRevision() {
        let source = Fixtures.clip(
            id: "source",
            mediaRef: "source-media",
            mediaType: .audio,
            start: 0,
            duration: 90
        )
        let e = editor([Fixtures.audioTrack(clips: [source])])
        let timelineId = e.activeTimelineId
        let snapshot = e.timeline

        e.timelineRenderRevision &+= 1

        #expect(e.captionPreparationIsCurrent(timelineId: timelineId, snapshot: snapshot))

        e.timeline.tracks[0].clips[0].startFrame += 1

        #expect(!e.captionPreparationIsCurrent(timelineId: timelineId, snapshot: snapshot))
    }

    @Test func largeCaptionSelectionResolvesWithinInteractionBudget() {
        let captions = (0..<10_000).map {
            Fixtures.clip(
                id: "caption-\($0)",
                mediaRef: "caption-media-\($0)",
                mediaType: .text,
                start: $0 * 30,
                duration: 30
            )
        }
        let e = editor([Fixtures.videoTrack(clips: captions)])
        var targets: [Clip] = []

        let duration = ContinuousClock().measure {
            targets = e.captionTargets(ids: captions.map(\.id))
        }

        #expect(targets.isEmpty)
        #expect(duration < .seconds(1))
    }

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
            Fixtures.audioTrack(id: "voice-track", clips: [voice]),
            Fixtures.audioTrack(id: "music-track", clips: [music]),
        ])

        #expect(e.captionTargets(ids: []).map(\.id) == ["audio", "voice", "music"])
        #expect(e.captionTargets(ids: ["video"]).map(\.id) == ["video"])
        #expect(e.captionTargets(trackIds: ["voice-track"]).map(\.id) == ["voice"])
        #expect(e.captionTargets(trackIds: ["video-track", "audio-track"]).map(\.id) == ["audio"])
        #expect(e.captionTargets(trackIds: ["video-track"]).isEmpty)
        #expect(e.captionTargets(trackIds: ["audio-track"]).map(\.id) == ["audio"])
    }

    @Test func explicitSelectionsCanChooseNonMasterMulticamMic() {
        var masterClip = Fixtures.clip(id: "master", mediaRef: "lapel", mediaType: .audio, start: 0, duration: 100)
        var roomClip = Fixtures.clip(id: "room", mediaRef: "room", mediaType: .audio, start: 0, duration: 100)
        masterClip.multicamGroupId = "group"
        roomClip.multicamGroupId = "group"
        let master = MulticamSource.Member(
            id: "master-member",
            mediaRef: "lapel",
            kind: .mic,
            angleLabel: "lapel",
            sync: .init(confidence: 1)
        )
        let room = MulticamSource.Member(
            mediaRef: "room",
            kind: .mic,
            angleLabel: "room",
            sync: .init(confidence: 1)
        )
        let e = editor([
            Fixtures.audioTrack(id: "master-track", clips: [masterClip]),
            Fixtures.audioTrack(id: "room-track", clips: [roomClip]),
        ])
        e.multicamGroups = [MulticamSource(
            id: "group",
            name: "Interview",
            members: [master, room],
            masterMemberId: master.id
        )]

        #expect(e.captionTargets(ids: []).map(\.id) == ["master"])
        #expect(e.captionTargets(ids: ["room"]).map(\.id) == ["room"])
        #expect(e.captionTargets(ids: ["master", "room"]).map(\.id) == ["master", "room"])
        #expect(e.transcriptionTargets(clipIds: ["room"]).map(\.id) == ["room"])
        #expect(e.captionTargets(trackIds: ["room-track"]).map(\.id) == ["room"])
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

@MainActor
@Suite struct CaptionProjectionTests {
    @Test func phrasesIgnoreWordsOutsideCurrentClipFragments() {
        let first = Fixtures.clip(id: "first", mediaRef: "media-1", mediaType: .audio, start: 0, duration: 30, trimStart: 0)
        let second = Fixtures.clip(id: "second", mediaRef: "media-1", mediaType: .audio, start: 30, duration: 30, trimStart: 60)
        let result = TranscriptionResult(
            text: "keep um go",
            language: "en",
            words: [
                TranscriptionWord(text: "keep", start: 0.1, end: 0.3),
                TranscriptionWord(text: "um", start: 1.1, end: 1.2),
                TranscriptionWord(text: "go", start: 2.1, end: 2.3),
            ],
            segments: [TranscriptionSegment(text: "keep um go", start: 0, end: 3)]
        )

        let firstPhrases = CaptionTranscriptMapper.phrases(
            for: first, result: result, fps: 30, maxWords: nil, minDuration: 0, fits: { _ in true }
        )
        let secondPhrases = CaptionTranscriptMapper.phrases(
            for: second, result: result, fps: 30, maxWords: nil, minDuration: 0, fits: { _ in true }
        )

        #expect(firstPhrases.map(\.text) == ["keep"])
        #expect(secondPhrases.map(\.text) == ["go"])
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
