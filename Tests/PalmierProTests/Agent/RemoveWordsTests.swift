import Foundation
import Testing
@testable import PalmierPro

@Suite("WordCutPlanner")
struct WordCutPlannerTests {
    typealias Word = WordCutPlanner.Word

    private func words(_ selected: Set<Int>) -> [Word] {
        [(0, 10), (11, 20), (21, 30), (31, 40)].enumerated().map {
            Word(startFrame: $0.element.0, endFrame: $0.element.1, selected: selected.contains($0.offset))
        }
    }

    @Test func cutSingleWord() {
        #expect(WordCutPlanner.cutRanges(words: words([1]), clipStart: 0, clipEnd: 100, keepGapFrames: 6)
            == [FrameRange(start: 11, end: 20)])
    }

    @Test func cutContiguousRun() {
        #expect(WordCutPlanner.cutRanges(words: words([1, 2]), clipStart: 0, clipEnd: 100, keepGapFrames: 6)
            == [FrameRange(start: 11, end: 30)])
    }

    @Test func cutNonAdjacentYieldsTwoRanges() {
        #expect(WordCutPlanner.cutRanges(words: words([0, 2]), clipStart: 0, clipEnd: 100, keepGapFrames: 0).count == 2)
    }

    @Test func cutOverlappingTimestamps() {
        let ws = [
            Word(startFrame: 0, endFrame: 10, selected: false),
            Word(startFrame: 9, endFrame: 20, selected: true),
            Word(startFrame: 19, endFrame: 30, selected: false),
        ]
        #expect(WordCutPlanner.cutRanges(words: ws, clipStart: 0, clipEnd: 100, keepGapFrames: 6)
            == [FrameRange(start: 9, end: 20)])
    }
}

@Suite("remove_words — param validation")
@MainActor
struct RemoveWordsParamTests {
    @Test func rejectsEmptyWords() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        #expect((await h.runRaw("remove_words", args: ["words": [Int]()]).isError))
    }

    @Test func parsesMixedSpans() throws {
        let spans = try ToolExecutor.parseWordSpans([3, [12, 18], 40])
        #expect(spans.count == 3)
        #expect(spans[0].0 == 3 && spans[0].1 == 3)
        #expect(spans[1].0 == 12 && spans[1].1 == 18)
        #expect(spans[2].0 == 40 && spans[2].1 == 40)
    }

    @Test func parsesWordMatches() throws {
        let matches = try ToolExecutor.parseWordMatches(["Um,", " uh ", "HMM"])
        #expect(matches == ["um", "uh", "hmm"])
    }

    @Test func rejectsEmptyMatches() {
        #expect(throws: ToolError.self) {
            _ = try ToolExecutor.parseWordMatches(["..."])
        }
    }
}

@Suite("remove_silence — param validation")
@MainActor
struct RemoveSilenceParamTests {
    @Test func omittedValuesUseCurrentSettings() throws {
        let current = try #require(SilenceRemovalSettings(
            minimumPauseSeconds: 1.25,
            speechPaddingSeconds: 0.2
        ))

        let parsed = try ToolExecutor.parseSilenceRemovalSettings([:], defaults: current)

        #expect(parsed == current)
    }

    @Test func acceptsPartialOneShotOverride() throws {
        let current = try #require(SilenceRemovalSettings(
            minimumPauseSeconds: 0.5,
            speechPaddingSeconds: 0.15
        ))

        let parsed = try ToolExecutor.parseSilenceRemovalSettings(
            ["minimumPauseSeconds": 1.0],
            defaults: current
        )

        #expect(parsed.minimumPauseSeconds == 1.0)
        #expect(parsed.speechPaddingSeconds == 0.15)
    }

    @Test func acceptsClipScopeWithoutChangingSettings() throws {
        let parsed = try ToolExecutor.parseSilenceRemovalSettings(
            ["clipIds": ["clip-1"]],
            defaults: .default
        )

        #expect(parsed == .default)
    }

    @Test func rejectsInvalidValuesAndUnknownKeys() {
        #expect(throws: ToolError.self) {
            _ = try ToolExecutor.parseSilenceRemovalSettings(
                ["minimumPauseSeconds": 0.1],
                defaults: .default
            )
        }
        #expect(throws: ToolError.self) {
            _ = try ToolExecutor.parseSilenceRemovalSettings(
                ["speechPaddingSeconds": "lots"],
                defaults: .default
            )
        }
        #expect(throws: ToolError.self) {
            _ = try ToolExecutor.parseSilenceRemovalSettings(
                ["persist": true],
                defaults: .default
            )
        }
    }

    @Test func overrideDoesNotChangeEditorSettings() async {
        let harness = ToolHarness()
        let before = harness.editor.silenceRemovalSettings

        _ = await harness.runRaw(
            "remove_silence",
            args: ["minimumPauseSeconds": 1.0, "speechPaddingSeconds": 0.25]
        )

        #expect(harness.editor.silenceRemovalSettings == before)
    }

    @Test func rejectsInvalidOrMissingClipScope() async {
        let harness = ToolHarness()

        #expect((await harness.runRaw("remove_silence", args: ["clipIds": []])).isError)
        #expect((await harness.runRaw("remove_silence", args: ["clipIds": [42]])).isError)
        #expect((await harness.runRaw("remove_silence", args: ["clipIds": ["missing-clip"]])).isError)
    }

    @Test func resolvesShortClipIdAndUsesClipScope() async {
        let clipId = "AAAAAAAA-1111-2222-3333-444444444444"
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: clipId, mediaType: .audio, start: 0, duration: 100),
            ]),
        ])
        let harness = ToolHarness(timeline: timeline)

        let result = await harness.runRaw(
            "remove_silence",
            args: ["clipIds": [String(clipId.prefix(8))]]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("No dead air in the selected clips"))
    }

    @Test func rejectsUnlinkedClipsAcrossTracks() async {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100),
            ]),
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: "a2", mediaType: .audio, start: 0, duration: 100),
            ]),
        ])
        let harness = ToolHarness(timeline: timeline)

        let result = await harness.runRaw(
            "remove_silence",
            args: ["clipIds": ["a1", "a2"]]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("must share one track"))
        #expect(!ToolHarness.textOf(result).contains("Ripple delete refused"))
    }

    @Test func rejectsScopeWithoutAnAudioClip() async {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "v1", mediaType: .video, start: 0, duration: 100),
            ]),
        ])
        let harness = ToolHarness(timeline: timeline)

        let result = await harness.runRaw(
            "remove_silence",
            args: ["clipIds": ["v1"]]
        )
        let message = ToolHarness.textOf(result)

        #expect(result.isError)
        #expect(message.contains("must include at least one audio clip"))
        #expect(!message.contains("No dead air"))
        #expect(!message.contains("Ripple delete refused"))
    }

    @Test func rejectsLinkedAudioClipsAcrossTracks() async {
        var first = Fixtures.clip(
            id: "a1", mediaType: .audio, start: 0, duration: 100
        )
        var second = Fixtures.clip(
            id: "a2", mediaType: .audio, start: 0, duration: 100
        )
        first.linkGroupId = "linked"
        second.linkGroupId = "linked"
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [first]),
            Fixtures.audioTrack(clips: [second]),
        ])
        let harness = ToolHarness(timeline: timeline)

        let result = await harness.runRaw(
            "remove_silence",
            args: ["clipIds": ["a1", "a2"]]
        )
        let message = ToolHarness.textOf(result)

        #expect(result.isError)
        #expect(message.contains("audio clips must come from one track"))
        #expect(!message.contains("Ripple delete refused"))
        #expect(harness.editor.timeline.tracks[0].clips == [first])
        #expect(harness.editor.timeline.tracks[1].clips == [second])
    }
}
