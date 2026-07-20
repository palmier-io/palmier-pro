import Foundation

/// Stores beats for each mediaRef. Avoids doing the same detection twice.
@MainActor
final class BeatStore {
    typealias CachedAnalysisLoader = @Sendable (URL, String) async -> BeatAnalysisCacheEntry?
    typealias FileTagLoader = @Sendable (URL) async -> String

    private var analyses: [String: BeatAnalysis] = [:]
    private var fileTags: [String: String] = [:]
    private var tasks: [String: (id: UUID, task: Task<BeatAnalysis, Error>)] = [:]
    private var hydrationTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private let cachedAnalysisLoader: CachedAnalysisLoader
    private let fileTagLoader: FileTagLoader

    var onBeatsReady: (() -> Void)?

    init(
        cachedAnalysisLoader: @escaping CachedAnalysisLoader = { sourceURL, mediaRef in
            await BeatDetector.cachedAnalysis(for: sourceURL, mediaRef: mediaRef)
        },
        fileTagLoader: @escaping FileTagLoader = { sourceURL in
            await DiskCache.loadSizeMtimeTag(for: sourceURL)
        }
    ) {
        self.cachedAnalysisLoader = cachedAnalysisLoader
        self.fileTagLoader = fileTagLoader
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
        if !force {
            if let running = tasks[key] { return running.task }
        }
        tasks[key]?.task.cancel()
        let id = UUID()
        let url = asset.url
        let existing = analyses[key]
        let existingTag = fileTags[key]
        let tagLoader = fileTagLoader
        let task = Task(priority: .utility) { @MainActor [weak self, weak asset] in
            guard let self else { throw CancellationError() }
            defer {
                if self.tasks[key]?.id == id {
                    self.tasks[key] = nil
                }
            }
            let tag = await tagLoader(url)
            try Task.checkCancellation()
            guard let asset, asset.url.standardizedFileURL == url.standardizedFileURL else {
                throw CancellationError()
            }
            if !force, let existing, existingTag == tag {
                return existing
            }
            let analysis = try await BeatDetector.analysis(for: url, mediaRef: key, force: force)
            try Task.checkCancellation()
            guard asset.url.standardizedFileURL == url.standardizedFileURL else {
                throw CancellationError()
            }
            self.analyses[key] = analysis
            self.fileTags[key] = tag
            self.onBeatsReady?()
            return analysis
        }
        tasks[key] = (id, task)
        return task
    }

    func reset() {
        tasks.values.forEach { $0.task.cancel() }
        hydrationTasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
        hydrationTasks.removeAll()
        analyses.removeAll()
        fileTags.removeAll()
    }

    func invalidate(_ mediaRef: String) {
        tasks.removeValue(forKey: mediaRef)?.task.cancel()
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
