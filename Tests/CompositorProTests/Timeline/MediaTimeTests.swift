import Foundation
import Testing
@testable import CompositorPro

@Suite("Media time and frame rate")
struct MediaTimeTests {
    @Test func standardRatesHaveExactTicksPerFrame() {
        #expect(FrameRate.fps23_976.ticksPerFrame == 5_005)
        #expect(FrameRate.fps29_97.ticksPerFrame == 4_004)
        #expect(FrameRate.fps30.ticksPerFrame == 4_000)
        #expect(FrameRate.fps24.ticksPerFrame == 5_000)
        #expect(FrameRate.fps25.ticksPerFrame == 4_800)
        #expect(FrameRate.fps60.ticksPerFrame == 2_000)
    }

    @Test func snapAndUnsnapIsExactForIntegerFrames() throws {
        for rate in [FrameRate.fps24, .fps25, .fps30, .fps60, .fps23_976, .fps29_97] {
            for frame in [Int64(0), 1, 23, 1_000, 10_001] {
                let time = try #require(rate.time(ofFrame: frame))
                #expect(rate.frameIndex(at: time, rounding: .floor) == frame)
                #expect(rate.frameIndex(at: time, rounding: .nearest) == frame)
            }
        }
    }

    @Test func roundingModesPickTheExpectedFrame() throws {
        let oneFrame = try #require(FrameRate.fps30.time(ofFrame: 1))
        let start = try #require(oneFrame.adding(MediaTime(ticks: 1_000)))
        #expect(FrameRate.fps30.frameIndex(at: start, rounding: .floor) == 1)
        #expect(FrameRate.fps30.frameIndex(at: start, rounding: .nearest) == 1)
        #expect(FrameRate.fps30.frameIndex(at: start, rounding: .ceil) == 2)

        let nearlyTwo = try #require(FrameRate.fps30.time(ofFrame: 2)?.subtracting(MediaTime(ticks: 100)))
        #expect(FrameRate.fps30.frameIndex(at: nearlyTwo, rounding: .nearest) == 2)
        #expect(FrameRate.fps30.frameIndex(at: nearlyTwo, rounding: .floor) == 1)
    }

    @Test func timecodeUsesNominalFrameNumbering() {
        #expect(FrameRate.fps30.timecode(forFrame: 0) == "00:00:00:00")
        #expect(FrameRate.fps30.timecode(forFrame: 29) == "00:00:00:29")
        #expect(FrameRate.fps30.timecode(forFrame: 30) == "00:00:01:00")
        #expect(FrameRate.fps25.timecode(forFrame: 25 * 61 + 4) == "00:01:01:04")
        #expect(FrameRate.fps24.timecode(forFrame: 24 * 3_600 + 24 * 60 + 24) == "01:01:01:00")
    }

    @Test func overflowAndInvalidInputAreRejected() throws {
        let maximum = MediaTime(ticks: Int64.max)
        #expect(maximum.adding(MediaTime(ticks: 1)) == nil)
        #expect(MediaTime(ticks: Int64.min).subtracting(MediaTime(ticks: 1)) == nil)
        #expect(MediaTime(seconds: .infinity) == nil)
        #expect(MediaTime(seconds: .nan) == nil)
        #expect(FrameRate(numerator: 0, denominator: 1) == nil)
        #expect(FrameRate(numerator: 30, denominator: 0) == nil)
        #expect(FrameRate(numerator: 60, denominator: 2) == FrameRate.fps30)
    }

    @Test func nonStandardRateWithoutExactTicksIsRejected() throws {
        let rate = try #require(FrameRate(numerator: 7, denominator: 1))
        #expect(rate.ticksPerFrame == nil)
        #expect(rate.frameIndex(at: MediaTime(ticks: 1)) == nil)
    }
}
