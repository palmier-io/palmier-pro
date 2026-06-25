import Foundation
import Testing
@testable import PalmierPro

@Suite("SilenceDetector")
struct SilenceDetectorTests {

    @Test func detectsSilentRunBetweenLoudSegments() {
        // 10 loud samples, 50 silent, 10 loud at 0.01s/hop = silence at [0.1, 0.6)
        let loud = [Float](repeating: 0.5, count: 10)
        let silent = [Float](repeating: 0.001, count: 50)
        let env = AudioEnvelope(hopSeconds: 0.01, samples: loud + silent + loud)
        let config = SilenceConfig(thresholdLinear: 0.02, minSilenceDuration: 0.3, edgePaddingSeconds: 0.0)
        let result = SilenceDetector.detect(envelope: env, config: config)
        #expect(result.count == 1)
        #expect(abs(result[0].start - 0.1) < 0.015)
        #expect(abs(result[0].end - 0.6) < 0.015)
    }

    @Test func filtersShortSilences() {
        // 50 loud, 5 silent (0.05s), 50 loud — shorter than minSilenceDuration 0.3s
        let loud = [Float](repeating: 0.5, count: 50)
        let silent = [Float](repeating: 0.001, count: 5)
        let env = AudioEnvelope(hopSeconds: 0.01, samples: loud + silent + loud)
        let config = SilenceConfig(thresholdLinear: 0.02, minSilenceDuration: 0.3, edgePaddingSeconds: 0.0)
        let result = SilenceDetector.detect(envelope: env, config: config)
        #expect(result.isEmpty)
    }

    @Test func appliesEdgePadding() {
        // 10 loud, 60 silent, 10 loud; padding=0.05s should shrink each edge by 5 samples
        let loud = [Float](repeating: 0.5, count: 10)
        let silent = [Float](repeating: 0.001, count: 60)
        let env = AudioEnvelope(hopSeconds: 0.01, samples: loud + silent + loud)
        let config = SilenceConfig(thresholdLinear: 0.02, minSilenceDuration: 0.3, edgePaddingSeconds: 0.05)
        let result = SilenceDetector.detect(envelope: env, config: config)
        #expect(result.count == 1)
        #expect(abs(result[0].start - 0.15) < 0.015)  // 0.1 + 0.05
        #expect(abs(result[0].end - 0.65) < 0.015)    // 0.7 - 0.05
    }

    @Test func paddingTooLargeDropsRange() {
        // 10 loud, 30 silent (0.3s), 10 loud; padding 0.2s each side leaves nothing
        let loud = [Float](repeating: 0.5, count: 10)
        let silent = [Float](repeating: 0.001, count: 30)
        let env = AudioEnvelope(hopSeconds: 0.01, samples: loud + silent + loud)
        let config = SilenceConfig(thresholdLinear: 0.02, minSilenceDuration: 0.3, edgePaddingSeconds: 0.2)
        let result = SilenceDetector.detect(envelope: env, config: config)
        #expect(result.isEmpty)
    }

    @Test func timelineRangesConvertsToFrames() {
        // Silence at source [0.5, 1.5); clip starts at frame 0, no trim, speed 1.0, fps=30
        let silences = [(start: 0.5, end: 1.5)]
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 300)  // 10s at 30fps
        let ranges = SilenceDetector.timelineRanges(silences: silences, clip: clip, fps: 30)
        #expect(ranges.count == 1)
        #expect(ranges[0].start == 15)  // 0.5 * 30
        #expect(ranges[0].end == 45)    // 1.5 * 30
    }

    @Test func timelineRangesAccountsForClipOffset() {
        // Clip starts at frame 90; silence at [0.5, 1.5) source seconds
        let silences = [(start: 0.5, end: 1.5)]
        let clip = Fixtures.clip(id: "c1", start: 90, duration: 300)
        let ranges = SilenceDetector.timelineRanges(silences: silences, clip: clip, fps: 30)
        #expect(ranges.count == 1)
        #expect(ranges[0].start == 105)  // 90 + 15
        #expect(ranges[0].end == 135)    // 90 + 45
    }

    @Test func timelineRangesAccountsForTrim() {
        // Clip trimmed by 1s (30 frames) at start; silence at source [0.5, 1.5).
        // Visible source starts at 1.0s, so silence is clamped to [1.0, 1.5).
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 270, trimStart: 30)
        let silences = [(start: 0.5, end: 1.5)]
        let ranges = SilenceDetector.timelineRanges(silences: silences, clip: clip, fps: 30)
        // tlStart = 0 + (1.0 - 1.0) / 1.0 * 30 = 0; tlEnd = 0 + (1.5 - 1.0) / 1.0 * 30 = 15
        #expect(ranges.count == 1)
        #expect(ranges[0].start == 0)
        #expect(ranges[0].end == 15)
    }

    @Test func timelineRangesDropsOutOfBoundsRanges() {
        // Silence entirely before clip content (before the trim point).
        let silences = [(start: 0.0, end: 0.1)]
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 270, trimStart: 30)
        let ranges = SilenceDetector.timelineRanges(silences: silences, clip: clip, fps: 30)
        #expect(ranges.isEmpty)
    }
}
