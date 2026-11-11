import AVFoundation
import Foundation

/// Cache of silence-detection results per media asset + settings, so repeated calls
/// with the same settings don't re-decode the audio. Main-actor state only; detection
/// itself runs off the main actor (see `ToolExecutor+Silence`).
@MainActor
final class SilenceStore {
    /// Cached silent segments keyed by `"mediaRef|threshold|minDuration|padding"`.
    private var results: [String: [SilenceDetector.Segment]] = [:]

    nonisolated func segments(for cacheKey: String) -> [SilenceDetector.Segment]? {
        MainActor.assumeIsolated { results[cacheKey] }
    }

    func install(_ segments: [SilenceDetector.Segment], for cacheKey: String) {
        results[cacheKey] = segments
    }

    func invalidate(_ cacheKey: String) {
        results.removeValue(forKey: cacheKey)
    }

    func reset() {
        results.removeAll()
    }
}

/// Cache key that folds in the detection settings so different thresholds/durations
/// never return stale cached segments.
func silenceCacheKey(
    mediaRef: String, thresholdDb: Double, minSilenceDuration: Double, paddingSeconds: Double
) -> String {
    "\(mediaRef)|\(thresholdDb)|\(minSilenceDuration)|\(paddingSeconds)"
}
