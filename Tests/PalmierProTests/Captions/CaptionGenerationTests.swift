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
        captionDurationFrames: Int? = nil,
        hasWordTiming: Bool = true
    ) -> CaptionSpecBuilder.Target {
        let clip = Fixtures.clip(
            id: id,
            mediaRef: "media-\(id)",
            mediaType: .audio,
            start: startFrame,
            duration: durationFrames
        )
        let captionDuration = Double(captionDurationFrames ?? min(21, durationFrames)) / 30
        let result = TranscriptionResult(
            text: id,
            language: "en",
            words: hasWordTiming ? [TranscriptionWord(text: id, start: 0, end: captionDuration)] : [],
            segments: [TranscriptionSegment(text: id, start: 0, end: captionDuration)]
        )
        return CaptionSpecBuilder.Target(
            clip: clip,
            result: result
        )
    }

    private func input(
        targets: [CaptionSpecBuilder.Target],
        maximumGapSeconds: Double = CaptionGapSettings.default.maximumGapSeconds,
        timelineEndFrame: Int? = nil,
        maxCharacters: Int? = nil,
        animation: TextAnimation? = nil
    ) -> CaptionSpecBuilder.Input {
        CaptionSpecBuilder.Input(
            targets: targets,
            fps: 30,
            timelineEndFrame: timelineEndFrame ?? targets.map(\.clip.endFrame).max() ?? 0,
            canvasWidth: 1920,
            canvasHeight: 1080,
            style: TextStyle(),
            center: CGPoint(x: 0.5, y: 0.8),
            textCase: .auto,
            maxWords: nil,
            maxCharacters: maxCharacters,
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
            timelineEndFrame: clip.endFrame,
            canvasWidth: 1920,
            canvasHeight: 1080,
            style: TextStyle(),
            center: CGPoint(x: 0.5, y: 0.8),
            textCase: .upper,
            maxWords: nil,
            maxCharacters: nil,
            gapSettings: .default,
            animation: nil
        )

        let specs = try await CaptionSpecBuilder.build(input)
        let spec = try #require(specs.first)

        #expect(specs.count == 1)
        #expect(spec.content == "HELLO WORLD")
        #expect(spec.startFrame == 30)
        #expect(spec.durationFrames == 45)
        #expect(spec.transform != nil)
        #expect(spec.words?.map(\.text) == ["hello", "world"])
    }

    @Test func appliesCharacterCapWhenBuildingCaptionSpecs() async throws {
        let clip = Fixtures.clip(
            mediaRef: "media",
            mediaType: .audio,
            start: 0,
            duration: 90
        )
        let result = TranscriptionResult(
            text: "one two three",
            language: "en",
            words: [
                TranscriptionWord(text: "one", start: 0, end: 0.2),
                TranscriptionWord(text: "two", start: 0.3, end: 0.5),
                TranscriptionWord(text: "three", start: 0.6, end: 0.8),
            ],
            segments: [TranscriptionSegment(text: "one two three", start: 0, end: 0.8)]
        )

        let specs = try await CaptionSpecBuilder.build(input(
            targets: [.init(clip: clip, result: result)],
            maxCharacters: 7
        ))

        #expect(specs.map(\.content) == ["one", "two", "three"])
    }

    @Test(arguments: [
        (6, 0.25, 27, 28),
        (7, 0.25, 28, 28),
        (8, 0.25, 21, 28),
        (6, 0.0, 21, 21),
    ])
    func closesOnlyGapsWithinTheFrameRoundedThreshold(
        gapFrames: Int,
        maximumGapSeconds: Double,
        expectedFirstDuration: Int,
        expectedLastDuration: Int
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
        #expect(specs.map(\.durationFrames) == [expectedFirstDuration, expectedLastDuration])
        #expect(specs[0].words == [WordTiming(text: "one", startFrame: 0, endFrame: 21)])
    }

    @Test(arguments: [
        TextAnimation.Preset.popIn,
        .slideUp,
        .typewriter,
        .wordReveal,
        .wordSlide,
    ])
    func closesAnimatedCaptionGapWithoutOverlap(
        preset: TextAnimation.Preset
    ) async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(id: "two", startFrame: 27, durationFrames: 30),
            ],
            animation: TextAnimation(preset: preset)
        ))

        #expect(specs.map(\.durationFrames) == [27, 30])
        #expect(specs[0].startFrame + specs[0].durationFrames == specs[1].startFrame)
        #expect(specs[0].words?.last?.endFrame == 21)
        #expect(specs[1].words?.last?.endFrame == 21)
    }

    @Test func oneFrameAnimatedCaptionClosesTheFollowingGapWithoutOverlap() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(id: "two", startFrame: 27, durationFrames: 1, hasWordTiming: false),
                gapTarget(id: "three", startFrame: 33, durationFrames: 30),
            ],
            animation: TextAnimation(preset: .popIn)
        ))

        #expect(specs.map(\.durationFrames) == [27, 6, 30])
        #expect(specs[0].startFrame + specs[0].durationFrames == specs[1].startFrame)
        #expect(specs[1].startFrame + specs[1].durationFrames == specs[2].startFrame)
    }

    @Test func trimsOverlapsWhenGapClosingIsDisabled() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(id: "two", startFrame: 20, durationFrames: 30),
            ],
            maximumGapSeconds: 0
        ))

        #expect(specs.map(\.startFrame) == [0, 20])
        #expect(specs.map(\.durationFrames) == [20, 21])
        #expect(specs[0].words?.last?.endFrame == 20)
    }

    @Test func trimsNestedOverlapsWithoutExtendingAcrossALongGap() async throws {
        let specs = try await CaptionSpecBuilder.build(input(targets: [
            gapTarget(id: "outer", startFrame: 0, durationFrames: 40),
            gapTarget(id: "nested", startFrame: 10, durationFrames: 5),
            gapTarget(id: "next", startFrame: 31, durationFrames: 30),
        ]))

        #expect(specs.map(\.startFrame) == [0, 10, 31])
        #expect(specs.map(\.durationFrames) == [10, 5, 30])
    }

    @Test func shorterPreviousCaptionOwnsOverlappingFrames() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 5),
                gapTarget(id: "two", startFrame: 4, durationFrames: 21),
            ],
            maximumGapSeconds: 0
        ))

        #expect(specs.map(\.content) == ["one", "two"])
        #expect(specs.map(\.startFrame) == [0, 5])
        #expect(specs.map(\.durationFrames) == [5, 20])
        #expect(specs[1].words == [WordTiming(text: "two", startFrame: 0, endFrame: 20)])
    }

    @Test func shorterNextCaptionOwnsOverlappingFrames() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(id: "two", startFrame: 20, durationFrames: 5),
            ],
            maximumGapSeconds: 0
        ))

        #expect(specs.map(\.content) == ["one", "two"])
        #expect(specs.map(\.startFrame) == [0, 20])
        #expect(specs.map(\.durationFrames) == [20, 5])
    }

    @Test func laterCaptionWinsEqualDurationTie() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 5),
                gapTarget(id: "two", startFrame: 4, durationFrames: 5),
            ],
            maximumGapSeconds: 0
        ))

        #expect(specs.map(\.startFrame) == [0, 4])
        #expect(specs.map(\.durationFrames) == [4, 5])
    }

    @Test func sameFrameCaptionsRemainSeparateAndCapped() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "one", startFrame: 0, durationFrames: 21),
                gapTarget(id: "two", startFrame: 0, durationFrames: 5),
            ],
            maximumGapSeconds: 0,
            maxCharacters: 3
        ))

        #expect(specs.map(\.content) == ["one", "two"])
        #expect(specs.map(\.startFrame) == [0, 1])
        #expect(specs.map(\.durationFrames) == [1, 4])
        #expect(specs.allSatisfy { $0.content.count <= 3 })
        #expect(specs[1].words == [WordTiming(text: "two", startFrame: 0, endFrame: 4)])
    }

    @Test func sameFrameCollisionChainPreservesEveryCaption() async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(id: "aaa", startFrame: 0, durationFrames: 3),
                gapTarget(id: "bb", startFrame: 0, durationFrames: 2),
                gapTarget(id: "c", startFrame: 0, durationFrames: 1),
            ],
            maximumGapSeconds: 0,
            maxCharacters: 3
        ))

        #expect(specs.map(\.content) == ["aaa", "bb", "c"])
        #expect(specs.map(\.startFrame) == [0, 1, 2])
        #expect(specs.map(\.durationFrames) == [1, 1, 1])
    }

    @Test(arguments: [
        (100, 0.5, 16),
        (10, 0.5, 10),
        (100, 0.0, 1),
    ])
    func holdsTheFinalCaptionWithinTheTimeline(
        timelineEndFrame: Int,
        maximumGapSeconds: Double,
        expectedDuration: Int
    ) async throws {
        let specs = try await CaptionSpecBuilder.build(input(
            targets: [
                gapTarget(
                    id: "last",
                    startFrame: 0,
                    durationFrames: timelineEndFrame,
                    captionDurationFrames: 1
                )
            ],
            maximumGapSeconds: maximumGapSeconds,
            timelineEndFrame: timelineEndFrame
        ))

        #expect(specs.map(\.durationFrames) == [expectedDuration])
    }

    @Test func captionGapSettingsValidateAndRoundDownToFrames() {
        #expect(CaptionGapSettings.default.maximumGapFrames(fps: 30) == 15)
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
    @Test(arguments: [true, false])
    func preservesShortTimingsAcrossTranscriptSegments(hasWordTimings: Bool) {
        let clip = Fixtures.clip(
            mediaRef: "media",
            mediaType: .audio,
            start: 0,
            duration: 60
        )
        let result = TranscriptionResult(
            text: "Sophie? Hi,",
            language: "en",
            words: hasWordTimings ? [
                TranscriptionWord(text: "Sophie?", start: 0, end: 0.2),
                TranscriptionWord(text: "Hi,", start: 0.3, end: 0.5),
            ] : [],
            segments: [
                TranscriptionSegment(text: "Sophie?", start: 0, end: 0.2),
                TranscriptionSegment(text: "Hi,", start: 0.3, end: 0.5),
            ]
        )

        let phrases = CaptionTranscriptMapper.phrases(
            for: clip,
            result: result,
            fps: 30,
            maxWords: nil,
            maxCharacters: 4,
            fits: { _ in true }
        )

        #expect(phrases.map(\.text) == ["Sophie?", "Hi,"])
        #expect(phrases.map(\.start) == [0, 0.3])
        #expect(phrases.map(\.end) == [0.2, 0.5])
    }

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
            for: first, result: result, fps: 30, maxWords: nil, maxCharacters: nil,
            fits: { _ in true }
        )
        let secondPhrases = CaptionTranscriptMapper.phrases(
            for: second, result: result, fps: 30, maxWords: nil, maxCharacters: nil,
            fits: { _ in true }
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
