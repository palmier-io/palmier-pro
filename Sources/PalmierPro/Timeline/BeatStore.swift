import Foundation

struct BeatStoreStaleAnalysisError: Error {}

@MainActor
@Observable
final class BeatStore {
    private var analyses: [String: BeatAnalysis] = [:]
    private var failed: Set<String> = []
    private var inFlight: Set<String> = []
    @ObservationIgnored private var epoch: [String: Int] = [:]

    @ObservationIgnored var onBeatsReady: (() -> Void)?

    nonisolated func analysis(for mediaRef: String) -> BeatAnalysis? {
        MainActor.assumeIsolated { analyses[mediaRef] }
    }

    func isAnalyzing(_ mediaRef: String) -> Bool { inFlight.contains(mediaRef) }
    func hasFailed(_ mediaRef: String) -> Bool { failed.contains(mediaRef) }

    func generate(for asset: MediaAsset, force: Bool = false, completion: (@MainActor (BeatAnalysis?) -> Void)? = nil) {
        let key = asset.id
        if !force, let existing = analyses[key] {
            completion?(existing)
            return
        }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        failed.remove(key)
        let startEpoch = epoch[key, default: 0]

        let url = asset.url
        Task.detached(priority: .utility) { [weak self] in
            var analysis: BeatAnalysis?
            do {
                analysis = try await BeatDetector.analysis(for: url, mediaRef: key, force: force)
            } catch {
                Log.preview.error("beats failed mediaRef=\(key): \(Log.detail(error))")
            }
            guard let self else { return }
            await MainActor.run { [self] in
                guard self.epoch[key, default: 0] == startEpoch else {
                    completion?(nil)
                    return
                }
                self.inFlight.remove(key)
                if let analysis {
                    self.analyses[key] = analysis
                    self.onBeatsReady?()
                } else {
                    self.failed.insert(key)
                }
                completion?(analysis)
            }
        }
    }

    func analysisAwaiting(for asset: MediaAsset) async throws -> BeatAnalysis {
        let key = asset.id
        if let existing = analyses[key] { return existing }

        inFlight.insert(key)
        failed.remove(key)
        let startEpoch = epoch[key, default: 0]
        defer { inFlight.remove(key) }

        let analysis = try await BeatDetector.analysis(for: asset.url, mediaRef: key)
        guard epoch[key, default: 0] == startEpoch else {
            if let existing = analyses[key] { return existing }
            throw BeatStoreStaleAnalysisError()
        }

        analyses[key] = analysis
        onBeatsReady?()
        return analysis
    }

    func reset() {
        for key in inFlight { epoch[key, default: 0] += 1 }
        inFlight.removeAll()
        analyses.removeAll()
        failed.removeAll()
    }

    func invalidate(_ mediaRef: String) {
        epoch[mediaRef, default: 0] += 1
        inFlight.remove(mediaRef)
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
