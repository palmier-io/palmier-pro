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
    /// Per-asset generation bumped by invalidation, plus a session epoch bumped by reset. A
    /// detection that started before either event must not republish its result.
    private var generations: [String: Int] = [:]
    private var epoch = 0

    nonisolated func segments(
        mediaRef: String, sourceIdentity: String, settings: SilenceDetectionSettings
    ) -> [SilenceDetector.Segment]? {
        MainActor.assumeIsolated {
            results[mediaRef]?[silenceCacheKey(sourceIdentity: sourceIdentity, settings: settings)]
        }
    }

    func beginDetection(mediaRef: String) -> SilenceDetectionToken {
        SilenceDetectionToken(
            mediaRef: mediaRef, generation: generations[mediaRef, default: 0], epoch: epoch
        )
    }

    func install(
        _ segments: [SilenceDetector.Segment],
        mediaRef: String,
        sourceIdentity: String,
        settings: SilenceDetectionSettings,
        token: SilenceDetectionToken
    ) -> Bool {
        guard token.mediaRef == mediaRef, isCurrent(token) else { return false }
        results[mediaRef, default: [:]][silenceCacheKey(sourceIdentity: sourceIdentity, settings: settings)] = segments
        return true
    }

    /// Drops every cached result for `mediaRef`, whatever its settings or source revision.
    func invalidate(mediaRef: String) {
        results.removeValue(forKey: mediaRef)
        generations[mediaRef, default: 0] += 1
    }

    func reset() {
        results.removeAll()
        epoch += 1
    }

    private func isCurrent(_ token: SilenceDetectionToken) -> Bool {
        generations[token.mediaRef, default: 0] == token.generation && epoch == token.epoch
    }
}

/// Identifies one in-flight detection so a result cannot be installed after the asset was
/// invalidated or the cache was reset.
struct SilenceDetectionToken: Equatable, Sendable {
    let mediaRef: String
    let generation: Int
    let epoch: Int
}

/// Cache key that folds in the source revision and the detection settings, so a relinked or
/// re-prepared asset and different thresholds/durations never return stale cached segments.
func silenceCacheKey(sourceIdentity: String, settings: SilenceDetectionSettings) -> String {
    "\(sourceIdentity)|\(settings.thresholdDb)|\(settings.minSilenceDuration)|\(settings.paddingSeconds)"
}