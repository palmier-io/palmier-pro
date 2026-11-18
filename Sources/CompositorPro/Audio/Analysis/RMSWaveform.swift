import Foundation

/// RMS waveform reduction for timeline audio. Values are normalized 0...1 and computed only for
/// the requested frame window, so long assets never need a full-timeline pass for a visible slice.
enum RMSWaveform {
    struct Slice: Sendable, Equatable {
        var values: [Float]
        var startIndex: Int
        var samplesPerColumn: Int

        var isEmpty: Bool { values.isEmpty }
    }

    /// RMS per window over `samples`, clamped to 0...1.
    static func reduce(samples: [Float], windowSize: Int) -> [Float] {
        guard windowSize > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity((samples.count + windowSize - 1) / windowSize)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + windowSize)
            var sum = 0.0
            for i in index..<end {
                let value = Double(samples[i])
                sum += value * value
            }
            out.append(Float(min(1, max(0, (sum / Double(end - index)).squareRoot()))))
            index = end
        }
        return out
    }

    /// Visible-window slice of a precomputed waveform: only columns covering `range` are copied.
    static func visibleSlice(_ values: [Float], range: Range<Int>) -> Slice {
        let lower = max(0, min(range.lowerBound, values.count))
        let upper = max(lower, min(range.upperBound, values.count))
        return Slice(values: Array(values[lower..<upper]), startIndex: lower, samplesPerColumn: 1)
    }

    /// Maps a timeline frame window to waveform columns for a clip's source range.
    static func columns(
        frameRange: Range<Int>,
        clipFrameRange: Range<Int>,
        columnCount: Int
    ) -> Range<Int> {
        guard columnCount > 0, clipFrameRange.count > 0 else { return 0..<0 }
        let clipFrames = Double(max(1, clipFrameRange.count))
        let columns = Double(columnCount)
        func column(for frame: Int) -> Int {
            let offset = Double(frame - clipFrameRange.lowerBound) / clipFrames
            return Int((offset * columns).rounded(.down))
        }
        let lower = min(columnCount, max(0, column(for: frameRange.lowerBound)))
        let upper = min(columnCount, max(lower, Int((Double(frameRange.upperBound - clipFrameRange.lowerBound) / clipFrames * columns).rounded(.up))))
        return lower..<upper
    }
}
