import Foundation

/// Stores beats for each mediaRef. Avoids doing the same detection twice.
@MainActor
final class BeatStore {
    private var analyses: [String: BeatAnalysis] = [:]
    private var fileTags: [String: String] = [:]
    private var tasks: [String: Task<BeatAnalysis, Error>] = [:]

    var onBeatsReady: (() -> Void)?

    nonisolated func analysis(for mediaRef: String) -> BeatAnalysis? {
        MainActor.assumeIsolated { analyses[mediaRef] }
    }

    /// Restores a prior session's analysis from the disk cache; never runs detection.
    func hydrate(for asset: MediaAsset) {
        let key = asset.id
        guard analyses[key] == nil, tasks[key] == nil,
              let cached = BeatDetector.cachedAnalysis(for: asset.url, mediaRef: key) else { return }
        analyses[key] = cached
        fileTags[key] = DiskCache.sizeMtimeTag(for: asset.url)
        onBeatsReady?()
    }

    @discardableResult
    func detect(for asset: MediaAsset, force: Bool = false) -> Task<BeatAnalysis, Error> {
        let key = asset.id
        let tag = DiskCache.sizeMtimeTag(for: asset.url)
        if !force {
            if let existing = analyses[key], fileTags[key] == tag { return Task { existing } }
            if let running = tasks[key] { return running }
        }
        tasks[key]?.cancel()
        let url = asset.url
        let task = Task(priority: .utility) { @MainActor in
            defer { if !Task.isCancelled { tasks[key] = nil } }
            let analysis = try await BeatDetector.analysis(for: url, mediaRef: key, force: force)
            try Task.checkCancellation()
            analyses[key] = analysis
            fileTags[key] = tag
            onBeatsReady?()
            return analysis
        }
        tasks[key] = task
        return task
    }

    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        analyses.removeAll()
        fileTags.removeAll()
    }

    func invalidate(_ mediaRef: String) {
        tasks.removeValue(forKey: mediaRef)?.cancel()
        analyses.removeValue(forKey: mediaRef)
        fileTags.removeValue(forKey: mediaRef)
    }
}

extension EditorViewModel {
    func beatSnapFrames(for clip: Clip) -> [Int] {
        guard markBeats, clip.sourceClipType != .sequence,
              let analysis = mediaVisualCache.beats.analysis(for: clip.mediaRef) else { return [] }
        let fps = timeline.fps
        let frames = (analysis.beats + analysis.downbeats).compactMap { clip.timelineFrame(sourceSeconds: $0, fps: fps) }
        return Array(Set(frames))
    }
}
