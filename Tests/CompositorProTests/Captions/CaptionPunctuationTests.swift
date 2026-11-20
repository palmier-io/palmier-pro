import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite struct CaptionPunctuationTests {
    private func input(
        clip: Clip,
        result: TranscriptionResult,
        maxCharacters: Int? = nil
    ) -> CaptionSpecBuilder.Input {
        CaptionSpecBuilder.Input(
            targets: [.init(clip: clip, result: result)],
            fps: 30,
            timelineEndFrame: clip.endFrame,
            canvasWidth: 1920,
            canvasHeight: 1080,
            style: TextStyle(),
            center: CGPoint(x: 0.5, y: 0.8),
            maxWidthRatio: 0.9,
            textCase: .auto,
            maxWords: nil,
            maxCharacters: maxCharacters,
            gapSettings: CaptionGapSettings(maximumGapSeconds: 0) ?? .default,
            animation: TextAnimation(preset: .wordSlide)
        )
    }

    @Test func generatedCaptionsRemoveCommasWithoutRetimingWords() async throws {
        let clip = Fixtures.clip(
            mediaType: .audio, start: 90, duration: 120, trimStart: 30, speed: 2
        )
        let result = TranscriptionResult(
            text: "Hello, 5,000,",
            language: "en",
            words: [
                TranscriptionWord(text: "Hello,", start: 1, end: 1.4),
                TranscriptionWord(text: "5,000,", start: 1.5, end: 2),
            ],
            segments: []
        )
        let specs = try await CaptionSpecBuilder.build(input(clip: clip, result: result))
        let spec = try #require(specs.first)

        #expect(specs.count == 1)
        #expect(spec.content == "Hello, 5,000")
        #expect(spec.startFrame == 90)
        #expect(spec.durationFrames == 15)
        #expect(spec.words == [
            WordTiming(text: "Hello,", startFrame: 0, endFrame: 6),
            WordTiming(text: "5,000", startFrame: 8, endFrame: 15),
        ])
        #expect(spec.animation?.preset == .wordSlide)
    }

    @Test func untimedCaptionsKeepOriginalClauseBoundariesAndDistributedTiming() async throws {
        let clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 60)
        let result = TranscriptionResult(
            text: "alpha, beta", language: "en", words: [],
            segments: [TranscriptionSegment(text: "alpha, beta", start: 0, end: 2)]
        )
        let specs = try await CaptionSpecBuilder.build(
            input(clip: clip, result: result, maxCharacters: 6)
        )

        #expect(specs.map(\.content) == ["alpha", "beta"])
        #expect(specs.map(\.startFrame) == [0, 36])
        #expect(specs.map(\.durationFrames) == [36, 24])
        #expect(specs.allSatisfy { $0.words == nil })
    }

    @Test func subtitleCaptionsRemoveCommasAndPreserveCueTimingAndLineBreaks() async throws {
        let specs = try await CaptionSpecBuilder.build(
            cues: [
                SubtitleCue(text: "Hello, 5,000\nworld,\n", startSeconds: 1, endSeconds: 2.5),
                SubtitleCue(text: "Next,", startSeconds: 4, endSeconds: 5),
            ],
            fps: 30, canvasWidth: 1920, canvasHeight: 1080,
            style: .caption, center: CGPoint(x: 0.5, y: 0.9),
            maxWidthRatio: DeliveryPlatform.generic.defaultCaptionPlacement().maxWidth
        )

        #expect(specs.map(\.content) == ["Hello, 5,000\nworld\n", "Next"])
        #expect(specs.map(\.startFrame) == [30, 120])
        #expect(specs.map(\.durationFrames) == [45, 30])
        let group = try #require(specs.first?.captionGroupId)
        #expect(specs.allSatisfy { $0.captionGroupId == group && $0.words == nil })
    }

    @Test func captionPreviewRemovesCommasWithoutRemovingOtherPunctuation() {
        let clip = CaptionPreviewRender.clip(
            content: "Hello, 5,000. Next?,", style: .caption, transform: Transform(),
            preset: .none, highlight: nil
        )

        #expect(clip.textContent == "Hello, 5,000. Next?")
    }

    @Test(arguments: [
        ("Hello, then,", "Hello, then"),
        ("5,000,", "5,000"),
        ("Hello,\nworld.", "Hello,\nworld."),
        ("Next, , \n", "Next  \n"),
        (",,,", ""),
        ("", ""),
    ])
    func onlyCaptionEndCommasAreRemoved(input: String, expected: String) {
        #expect(CaptionPunctuation.normalized(input) == expected)
    }

    @Test func transcriptOnlySpecsRetainCommasAndWordText() throws {
        let clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 60)
        let specs = CaptionBuilder.specs(
            for: [.init(text: "Hello, 5,000,", start: 0, end: 2, words: [
                .init(text: "Hello,", start: 0, end: 1),
                .init(text: "5,000,", start: 1, end: 2),
            ])],
            sourceClip: clip, trackIndex: 0, fps: 30, style: .caption, captionGroupId: nil
        )
        let spec = try #require(specs.first)

        #expect(spec.content == "Hello, 5,000,")
        #expect(spec.words == [
            WordTiming(text: "Hello,", startFrame: 0, endFrame: 30),
            WordTiming(text: "5,000,", startFrame: 30, endFrame: 60),
        ])
        #expect(spec.captionGroupId == nil)
    }
}
