import AVFoundation

enum SourceMediaTimebase {
    static func absoluteTime(relativeSeconds: Double, trackStart: CMTime) -> CMTime {
        trackStart + CMTime(seconds: relativeSeconds, preferredTimescale: 60_000)
    }

    static func absoluteTime(relativeFrame: Int, fps: Int, trackStart: CMTime) -> CMTime {
        trackStart + CMTime(value: CMTimeValue(relativeFrame), timescale: CMTimeScale(fps))
    }

    static func relativeSeconds(absoluteTime: CMTime, trackStart: CMTime) -> Double {
        (absoluteTime - trackStart).seconds
    }

    static func relativeSeconds(relativeFrame: Int, fps: Int) -> Double {
        Double(relativeFrame) / Double(max(1, fps))
    }

    static func relativeFrame(absoluteTime: CMTime, fps: Int, trackStart: CMTime) -> Int {
        let seconds = relativeSeconds(absoluteTime: absoluteTime, trackStart: trackStart)
        guard seconds.isFinite else { return 0 }
        return secondsToFrame(seconds: max(0, seconds), fps: fps)
    }
}
