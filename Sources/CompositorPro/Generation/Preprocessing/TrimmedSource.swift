import AVFoundation
import Foundation

struct TrimmedSource: Sendable {
    let sourceURL: URL
    let trimStartFrame: Int
    let trimEndFrame: Int
    let sourceFramesConsumed: Int
    let fps: Int

    var hasTrim: Bool { trimStartFrame > 0 || trimEndFrame > 0 }
    var durationSeconds: Double { Double(sourceFramesConsumed) / Double(max(1, fps)) }
    var timeRange: CMTimeRange {
        let timescale = CMTimeScale(max(1, fps))
        return CMTimeRange(
            start: CMTime(value: CMTimeValue(trimStartFrame), timescale: timescale),
            duration: CMTime(value: CMTimeValue(sourceFramesConsumed), timescale: timescale)
        )
    }
}
