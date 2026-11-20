import AVFoundation

enum CompositionSourceTiming {
    static func requestedRange(
        for clip: Clip,
        timeMap: SourceTimeMap,
        timescale: CMTimeScale,
        sourceTimescale: CMTimeScale
    ) -> CMTimeRange {
        let trimStartFrame = clip.mediaType == .image ? max(0, clip.trimStartFrame) : clip.trimStartFrame
        let start = CMTime(seconds: Double(trimStartFrame) / Double(timescale), preferredTimescale: sourceTimescale)
        let duration = CMTime(seconds: Double(timeMap.sourceFramesConsumed) / Double(timescale),
            preferredTimescale: sourceTimescale)
        return CMTimeRange(start: start, duration: duration)
    }
}
