import Foundation

/// Decides when an export has stalled based on `AVAssetExportSession.progress`
/// samples. Pure logic — time is fed in as a `Duration` so it is fully testable.
///
/// `AVAssetExportSession` can hang indefinitely on deep seeks into high-frame-rate
/// sources inside a lower-frame-rate timeline (#68); this turns that into a
/// cancellable error instead of a frozen progress bar.
struct ExportStallWatcher {
    static let defaultEpsilon: Double = 0.0005

    let epsilon: Double
    private(set) var lastProgress: Double?
    private(set) var lastAdvancedAt: Duration

    init(epsilon: Double = ExportStallWatcher.defaultEpsilon, startOffset: Duration = .zero) {
        self.epsilon = epsilon
        self.lastAdvancedAt = startOffset
    }

    /// Feed one progress sample taken at absolute monotonic offset `now`.
    /// Returns true when progress has been frozen for at least `stallLimit`.
    @discardableResult
    mutating func update(progress: Double, now: Duration, stallLimit: Duration) -> Bool {
        if let last = lastProgress, abs(progress - last) > epsilon {
            lastAdvancedAt = now
        }
        lastProgress = progress
        return stallLimit > .zero && now - lastAdvancedAt >= stallLimit
    }
}
