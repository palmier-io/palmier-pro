import Testing
@testable import PalmierPro

@Suite("Audio meter")
struct AudioMeterTests {
    @Test func analyzesStereoAndClampsRanges() {
        let analysis = AudioLevelAnalyzer.analyze(
            left: [0, -0.5, 0.25, -1],
            right: [0.25, -0.25, 0.25, -0.25],
            range: -4..<20
        )
        let empty = AudioLevelAnalyzer.analyze(left: [], right: [], range: 0..<1)

        #expect(abs(analysis.left.peak - 1) < 0.0001)
        #expect(abs(analysis.left.rms - 0.57282) < 0.0001)
        #expect(abs(analysis.right.peak - 0.25) < 0.0001)
        #expect(abs(analysis.right.rms - 0.25) < 0.0001)
        #expect(empty == .silence)
    }

    @Test func holdsPeakAndDecaysLevel() {
        var state = AudioMeterChannelState()
        state.ingest(rms: 0.25, peak: 0.5, at: 10)
        let initial = state.display(at: 10)
        let afterOneSecond = state.display(at: 11)
        let afterTwoSeconds = state.display(at: 12)

        #expect(abs(initial.levelDb - -12.0412) < 0.001)
        #expect(abs(initial.peakDb - -6.0206) < 0.001)
        #expect(abs(afterOneSecond.levelDb - -36.0412) < 0.001)
        #expect(abs(afterOneSecond.peakDb - initial.peakDb) < 0.001)
        #expect(abs(afterTwoSeconds.peakDb - -15.0206) < 0.001)
    }

    @Test func latchesClippingUntilReset() {
        var state = AudioMeterChannelState()
        state.ingest(rms: 0.5, peak: 1.01, at: 0)
        state.ingest(rms: 0, peak: 0, at: 3)
        #expect(state.display(at: 3).clipped)
        state.resetClipping()
        #expect(!state.display(at: 3).clipped)
    }
}
