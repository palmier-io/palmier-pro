import Foundation
import Testing
@testable import PalmierPro

@Suite("TimecodeSync")
struct TimecodeSyncTests {
    private let ntsc = 1001.0 / 30000.0

    @Test func secondsPrefersExactFrameDuration() {
        #expect(SourceTimecode(frame: 250, quanta: 50, dropFrame: false).seconds == 5.0)
        let tc = SourceTimecode(frame: 30000, quanta: 30, dropFrame: true, frameDuration: ntsc)
        #expect(abs(tc.seconds - 1001.0) < 1e-9)
        // Quanta-only NTSC would land ~18 frames off per 10 minutes of offset.
        let quantaOnly = SourceTimecode(frame: 17982, quanta: 30, dropFrame: true)
        let exact = SourceTimecode(frame: 17982, quanta: 30, dropFrame: true, frameDuration: ntsc)
        #expect(abs(quantaOnly.seconds - exact.seconds) > 0.5)
    }

    @Test func timecodeAlignedStartHandlesOffsetTrimAndSpeed() {
        func start(refStart: Int = 0, refTrim: Int = 0, refSpeed: Double = 1,
                   refFrame: Int, targetTrim: Int = 0, targetFrame: Int) -> Int {
            EditorViewModel.timecodeAlignedStart(
                refStartFrame: refStart, refTrimStartFrame: refTrim, refSpeed: refSpeed,
                refTimecode: SourceTimecode(frame: refFrame, quanta: 25, dropFrame: false),
                targetTrimStartFrame: targetTrim,
                targetTimecode: SourceTimecode(frame: targetFrame, quanta: 25, dropFrame: false), fps: 25)
        }
        #expect(start(refStart: 120, refFrame: 90000, targetFrame: 90000) == 120)   // equal TC → same start
        #expect(start(refFrame: 1000, targetFrame: 1250) == 250)                    // +10s TC → +250f
        #expect(start(refStart: 100, refTrim: 50, refFrame: 0, targetFrame: 0) == 50) // ref trim shifts clock
        #expect(start(refSpeed: 2, refFrame: 0, targetFrame: 250) == 125)           // lag scales by ref speed
    }

    @Test func parsesQuickTimeCaptureDates() {
        // iPhone files write both timezone spellings.
        let colon = SourceTimingReader.parseQuickTimeDate("2026-07-06T12:24:41-07:00")
        #expect(colon != nil)
        #expect(colon == SourceTimingReader.parseQuickTimeDate("2026-07-06T12:24:41-0700"))
        #expect(SourceTimingReader.parseQuickTimeDate("not a date") == nil)
    }

    @Test func seededCorrelationFindsLagOutsideSymmetricWindow() {
        var state: UInt64 = 42
        func noise(_ n: Int) -> [Float] {
            (0..<n).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float((state >> 33) % 1000) / 1000
            }
        }
        var reference = [Float](repeating: 0, count: 4000)
        let target = noise(400)
        reference.replaceSubrange(3000..<3400, with: target)
        #expect(AudioSyncCorrelator.correlate(reference: reference, target: target, maxLagHops: 100)?.lagHops != 3000)
        let seeded = AudioSyncCorrelator.correlate(reference: reference, target: target, maxLagHops: 100, centerLagHops: 2950)
        #expect(seeded?.lagHops == 3000)
        #expect((seeded?.confidence ?? 0) > 0.99)
        // A thin shared edge (30 hops) wins loose correlation but is rejected by a real overlap floor.
        var ref2 = noise(2000)
        var tgt2 = noise(1000)
        let shared = noise(30)
        ref2.replaceSubrange(1970..<2000, with: shared)
        tgt2.replaceSubrange(0..<30, with: shared)
        #expect(AudioSyncCorrelator.correlate(reference: ref2, target: tgt2, maxLagHops: 1970)?.lagHops == 1970)
        let strict = AudioSyncCorrelator.correlate(reference: ref2, target: tgt2, maxLagHops: 1970, minOverlapHops: 300)
        #expect(strict?.lagHops != 1970)
        #expect((strict?.confidence ?? 1) < 0.5)
    }
}
