import Foundation
import Testing
@testable import CompositorPro

@Suite("RMS waveform")
struct RMSWaveformTests {
    @Test func reducesSilenceAndFullScale() {
        #expect(RMSWaveform.reduce(samples: [Float](repeating: 0, count: 100), windowSize: 10).allSatisfy { $0 == 0 })
        let full = RMSWaveform.reduce(samples: [Float](repeating: 1, count: 100), windowSize: 10)
        #expect(full.count == 10)
        #expect(full.allSatisfy { abs($0 - 1) < 0.0001 })
    }

    @Test func sineWaveHasExpectedRMS() {
        let samples = (0..<10_000).map { Float(sin(Double($0) * 0.05)) }
        let rms = RMSWaveform.reduce(samples: samples, windowSize: 1_000)
        #expect(rms.count == 10)
        // A sine's RMS is 1/sqrt(2) ≈ 0.707.
        for value in rms { #expect(abs(value - 0.707) < 0.05) }
    }

    @Test func visibleSliceCopiesOnlyTheRequestedColumns() {
        let values = (0..<100).map { Float($0) }
        let slice = RMSWaveform.visibleSlice(values, range: 20..<30)
        #expect(slice.values == Array(20..<30).map { Float($0) })
        #expect(slice.startIndex == 20)
        #expect(RMSWaveform.visibleSlice(values, range: 90..<500).values.count == 10)
        #expect(RMSWaveform.visibleSlice(values, range: 500..<600).values.isEmpty)
    }

    @Test func frameWindowsMapToColumns() {
        let all = RMSWaveform.columns(frameRange: 0..<300, clipFrameRange: 0..<300, columnCount: 100)
        #expect(all == 0..<100)
        let middle = RMSWaveform.columns(frameRange: 150..<300, clipFrameRange: 0..<300, columnCount: 100)
        #expect(middle == 50..<100)
        #expect(RMSWaveform.columns(frameRange: 0..<0, clipFrameRange: 0..<300, columnCount: 100).isEmpty)
        #expect(RMSWaveform.columns(frameRange: 0..<10, clipFrameRange: 0..<0, columnCount: 100).isEmpty)
    }

    @Test func invalidWindowsAreRefused() {
        #expect(RMSWaveform.reduce(samples: [1, 2, 3], windowSize: 0).isEmpty)
        #expect(RMSWaveform.reduce(samples: [], windowSize: 4).isEmpty)
    }
}
