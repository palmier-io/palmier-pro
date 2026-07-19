import Foundation

/// Stores beats for each mediaRef. Avoids doing the same detection twice.
@MainActor
final class BeatStore {
    typealias CachedAnalysisLoader = @Sendable (URL, String) async -> BeatAnalysisCacheEntry?

    private var analyses: [String: BeatAnalysis] = [:]
    private var fileTags: [String: String] = [:]
    private var tasks: [String: Task<BeatAnalysis, Error>] = [:]
    private var hydrationTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private let cachedAnalysisLoader: CachedAnalysisLoader

    var onBeatsReady: (() -> Void)?

    init(
        cachedAnalysisLoader: @escaping CachedAnalysisLoader = { sourceURL, mediaRef in
            await BeatDetector.cachedAnalysis(for: sourceURL, mediaRef: mediaRef)
        }
    ) {
        self.cachedAnalysisLoader = cachedAnalysisLoader
    }

    nonisolated func analysis(for mediaRef: String) -> BeatAnalysis? {
        MainActor.assumeIsolated { analyses[mediaRef] }
    }

    /// Restores a prior session's analysis from the disk cache; never runs detection.
    @discardableResult
    func hydrate(for asset: MediaAsset) -> Task<Void, Never>? {
        let key = asset.id
        guard analyses[key] == nil, tasks[key] == nil else { return nil }
        if let hydration = hydrationTasks[key] { return hydration.task }
        let id = UUID()
        let url = asset.url
        let loader = cachedAnalysisLoader
        let task = Task(priority: .utility) { @MainActor [weak self, weak asset] in
            let entry = await loader(url, key)
            guard let self, self.hydrationTasks[key]?.id == id else { return }
            self.hydrationTasks.removeValue(forKey: key)
            guard !Task.isCancelled, let asset else { return }
            guard asset.url.standardizedFileURL == url.standardizedFileURL else {
                self.hydrate(for: asset)
                return
            }
            guard self.tasks[key] == nil,
                  self.analyses[key] == nil,
                  let entry else { return }
            self.analyses[key] = entry.analysis
            self.fileTags[key] = entry.fileTag
            self.onBeatsReady?()
        }
        hydrationTasks[key] = (id, task)
        return task
    }

    @discardableResult
    func detect(for asset: MediaAsset, force: Bool = false) -> Task<BeatAnalysis, Error> {
        let key = asset.id
        hydrationTasks.removeValue(forKey: key)?.task.cancel()
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
        hydrationTasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
        hydrationTasks.removeAll()
        analyses.removeAll()
        fileTags.removeAll()
    }

    func invalidate(_ mediaRef: String) {
        tasks.removeValue(forKey: mediaRef)?.cancel()
        hydrationTasks.removeValue(forKey: mediaRef)?.task.cancel()
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
