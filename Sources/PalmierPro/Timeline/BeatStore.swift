import Foundation

struct BeatStoreStaleAnalysisError: Error {}

@MainActor
@Observable
final class BeatStore {
    private var analyses: [String: BeatAnalysis] = [:]
    private var failed: Set<String> = []
    @ObservationIgnored private var tasks: [String: (id: Int, force: Bool, task: Task<BeatAnalysis, Error>)] = [:]
    @ObservationIgnored private var nextTaskID = 0
    @ObservationIgnored private var epoch: [String: Int] = [:]

    @ObservationIgnored var onBeatsReady: (() -> Void)?

    nonisolated func analysis(for mediaRef: String) -> BeatAnalysis? {
        MainActor.assumeIsolated { analyses[mediaRef] }
    }

    func isAnalyzing(_ mediaRef: String) -> Bool { tasks[mediaRef] != nil }
    func hasFailed(_ mediaRef: String) -> Bool { failed.contains(mediaRef) }

    func generate(for asset: MediaAsset, force: Bool = false, completion: (@MainActor (BeatAnalysis?) -> Void)? = nil) {
        if !force, let existing = analyses[asset.id] {
            completion?(existing)
            return
        }
        let task = detectionTask(for: asset, force: force)
        guard let completion else { return }
        Task { completion(try? await task.value) }
    }

    func analysisAwaiting(for asset: MediaAsset) async throws -> BeatAnalysis {
        // Join any in-flight detection so a forced redetect never answers with the stale cache.
        if tasks[asset.id] == nil, let existing = analyses[asset.id] { return existing }
        do {
            return try await detectionTask(for: asset, force: false).value
        } catch {
            if let existing = analyses[asset.id] { return existing }
            throw error
        }
    }

    /// One in-flight task per mediaRef; every caller joins it. A forced request
    /// supersedes a non-forced one by chaining after it, so redetect never gets
    /// downgraded to a cache hit. Results are dropped when `invalidate`/`reset`
    /// bumped `epoch` while the analysis was running.
    private func detectionTask(for asset: MediaAsset, force: Bool) -> Task<BeatAnalysis, Error> {
        let key = asset.id
        let predecessor = tasks[key]
        if let predecessor, !force || predecessor.force { return predecessor.task }

        failed.remove(key)
        let startEpoch = epoch[key, default: 0]
        nextTaskID += 1
        let id = nextTaskID

        let url = asset.url
        let previous = predecessor?.task
        let task = Task(priority: .utility) { @MainActor [weak self] in
            _ = try? await previous?.value
            do {
                let analysis = try await BeatDetector.analysis(for: url, mediaRef: key, force: force)
                guard let self, self.epoch[key, default: 0] == startEpoch else {
                    throw BeatStoreStaleAnalysisError()
                }
                if self.tasks[key]?.id == id { self.tasks[key] = nil }
                self.analyses[key] = analysis
                self.onBeatsReady?()
                return analysis
            } catch {
                if !(error is BeatStoreStaleAnalysisError) {
                    Log.preview.error("beats failed mediaRef=\(key): \(Log.detail(error))")
                }
                if let self, self.epoch[key, default: 0] == startEpoch {
                    if self.tasks[key]?.id == id { self.tasks[key] = nil }
                    self.failed.insert(key)
                }
                throw error
            }
        }
        tasks[key] = (id, force, task)
        return task
    }

    func reset() {
        for key in tasks.keys { epoch[key, default: 0] += 1 }
        tasks.removeAll()
        analyses.removeAll()
        failed.removeAll()
    }

    func invalidate(_ mediaRef: String) {
        epoch[mediaRef, default: 0] += 1
        tasks.removeValue(forKey: mediaRef)
        analyses.removeValue(forKey: mediaRef)
        failed.remove(mediaRef)
    }
}

extension EditorViewModel {
    func beatSnapFrames(for clip: Clip) -> [Int] {
        guard clip.sourceClipType != .sequence,
              let analysis = mediaVisualCache.beats.analysis(for: clip.mediaRef) else { return [] }
        let fps = timeline.fps
        return analysis.beats.compactMap { clip.timelineFrame(sourceSeconds: $0, fps: fps) }
    }
}
