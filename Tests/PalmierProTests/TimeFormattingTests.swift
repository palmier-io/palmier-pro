import Testing
@testable import PalmierPro

@Suite("formatTimecode")
struct FormatTimecodeTests {

    @Test func zeroFrameIsAllZeros() {
        #expect(formatTimecode(frame: 0, fps: 30) == "00:00:00:00")
    }

    @Test func framesRollIntoSecondsAtFpsBoundary() {
        #expect(formatTimecode(frame: 29, fps: 30) == "00:00:00:29")
        #expect(formatTimecode(frame: 30, fps: 30) == "00:00:01:00")
    }

    @Test func secondsRollIntoMinutes() {
        // 60s × 30fps = 1800 frames → 1 minute.
        #expect(formatTimecode(frame: 1800, fps: 30) == "00:01:00:00")
    }

    @Test func minutesRollIntoHours() {
        // 3600s × 30fps = 108000 frames → 1 hour.
        #expect(formatTimecode(frame: 108000, fps: 30) == "01:00:00:00")
    }

    @Test func twoDigitPaddingHoldsBelowTen() {
        // 5s × 30fps = 150 frames → "00:00:05:00", not "00:00:5:00".
        #expect(formatTimecode(frame: 150, fps: 30) == "00:00:05:00")
    }

    @Test func zeroFpsReturnsFallbackInsteadOfDividingByZero() {
        #expect(formatTimecode(frame: 100, fps: 0) == "00:00:00:00")
    }

    @Test func twentyFourFpsRollsAtTwentyFour() {
        #expect(formatTimecode(frame: 23, fps: 24) == "00:00:00:23")
        #expect(formatTimecode(frame: 24, fps: 24) == "00:00:01:00")
    }
}

@Suite("frame/seconds conversion")
struct FrameSecondsConversionTests {

    @Test func frameToSecondsDividesByFps() {
        #expect(frameToSeconds(frame: 60, fps: 30) == 2.0)
        #expect(frameToSeconds(frame: 15, fps: 30) == 0.5)
        #expect(frameToSeconds(frame: 0, fps: 30) == 0)
    }

    @Test func frameToSecondsHandlesZeroFps() {
        #expect(frameToSeconds(frame: 100, fps: 0) == 0)
    }

    @Test func secondsToFrameMultipliesByFps() {
        #expect(secondsToFrame(seconds: 2.0, fps: 30) == 60)
        #expect(secondsToFrame(seconds: 0.5, fps: 30) == 15)
    }

    @Test func secondsToFrameTruncatesFractionalResult() {
        // 0.45 * 30 = 13.5 → Int truncates to 13, doesn't round.
        #expect(secondsToFrame(seconds: 0.45, fps: 30) == 13)
        // 0.4 * 30 = 12.0 → 12.
        #expect(secondsToFrame(seconds: 0.4, fps: 30) == 12)
    }
}

// MARK: - Adversarial

@Suite("TimeFormatting — adversarial")
struct TimeFormattingAdversarialTests {

    /// Frame → seconds → frame should round-trip at common frame counts.
    /// IEEE 754 multiply-after-divide cancels the floating error for these inputs,
    /// so this passes today; it'd break if either function changed precision.
    @Test func frameSecondsRoundtripAtCommonFrames() {
        for f in [0, 1, 15, 29, 30, 31, 59, 60, 61] {
            let s = frameToSeconds(frame: f, fps: 30)
            let back = secondsToFrame(seconds: s, fps: 30)
            #expect(back == f, "round-trip lost for frame \(f): seconds=\(s) → back=\(back)")
        }
    }

    @Test func negativeFrameFormatsWithLeadingSign() {
        // SMPTE-style signed timecode: one `-` at the front, fields well-formed.
        #expect(formatTimecode(frame: -30, fps: 30) == "-00:00:01:00")
        #expect(formatTimecode(frame: -1, fps: 30) == "-00:00:00:01")
        // Positive case unchanged.
        #expect(formatTimecode(frame: 30, fps: 30) == "00:00:01:00")
    }

    @Test func formatTimecodeAtVeryLargeFrameStillProducesOutput() {
        let result = formatTimecode(frame: 3_000_000, fps: 30)
        #expect(result.split(separator: ":").count == 4)
    }
}
