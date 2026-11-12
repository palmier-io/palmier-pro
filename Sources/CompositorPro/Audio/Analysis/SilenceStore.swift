import AVFoundation
import Foundation

/// Cache of silence-detection results per media asset, source revision, and settings, so
/// repeated calls with the same settings don't re-decode the audio. Main-actor state only;
/// detection itself runs off the main actor (see `ToolExecutor+Silence`).
@MainActor
final class SilenceStore {
    /// Cached silent segments keyed by asset id, then by source identity + settings. Nesting by
    /// asset keeps every settings variant invalidatable when a source is relinked or reset.
    private var results: [String: [String: [SilenceDetector.Segment]]] = [:]

    nonisolated func segments(
        mediaRef: String, sourceIdentity: String, settings: SilenceDetectionSettings
    ) -> [SilenceDetector.Segment]? {
        MainActor.assumeIsolated {
            results[mediaRef]?[silenceCacheKey(sourceIdentity: sourceIdentity, settings: settings)]
        }
    }

    func install(
        _ segments: [SilenceDetector.Segment],
        mediaRef: String,
        sourceIdentity: String,
        settings: SilenceDetectionSettings
    ) {
        results[mediaRef, default: [:]][silenceCacheKey(sourceIdentity: sourceIdentity, settings: settings)] = segments
    }

    /// Drops every cached result for `mediaRef`, whatever its settings or source revision.
    func invalidate(mediaRef: String) {
        results.removeValue(forKey: mediaRef)
    }

    func reset() {
        results.removeAll()
    }
}

/// Cache key that folds in the source revision and the detection settings, so a relinked or
/// re-prepared asset and different thresholds/durations never return stale cached segments.
func silenceCacheKey(sourceIdentity: String, settings: SilenceDetectionSettings) -> String {
    "\(sourceIdentity)|\(settings.thresholdDb)|\(settings.minSilenceDuration)|\(settings.paddingSeconds)"
}