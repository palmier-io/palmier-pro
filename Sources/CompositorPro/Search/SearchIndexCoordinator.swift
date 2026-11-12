import Foundation

/// Per-project indexing queue and search
@MainActor
@Observable
final class SearchIndexCoordinator {
    struct PreflightRequest: Sendable {
        let url: URL
        let type: ClipType
        let hasAudio: Bool
        let spec: VisualEmbedder.Spec
    }

    struct PreflightResult: Equatable, Sendable {
        let needsVisual: Bool
        let needsTranscript: Bool

        var needsIndex: Bool { needsVisual || needsTranscript }
    }

    private struct AssetSnapshot: Equatable, Sendable {
        let id: String
        let url: URL
        let type: ClipType
        let duration: Double
        let hasAudio: Bool
        let isGenerating: Bool
    }

    private struct IndexWork: Sendable {
        let asset: AssetSnapshot
        let spec: VisualEmbedder.Spec
    }

    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    private(set) var currentAssetFraction: Double = 0

    var indexingActive: Bool { batchCompleted < batchTotal }
    var indexingProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchCompleted) + min(max(currentAssetFraction, 0), 1)) / Double(batchTotal))
    }

    var assetsProvider: () -> [MediaAsset] = { [] }

    private var queue: [IndexWork] = []
    private var scheduledIds: Set<String> = []
    private var isCancelling = false
    private var failedIds: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Bumped whenever `worker` is replaced or cancelled, so a stale worker's
    /// exit path can't clobber the reference to a newer one.
    private var workerGeneration = 0
    private var loadedIndexes: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]

    private static let registry = NSHashTable<SearchIndexCoordinator>.weakObjects()
    private static var live: [SearchIndexCoordinator] { registry.allObjects }

    init() {
        Self.registry.add(self)
    }

    // MARK: - App-level fan-out

    static func sweepAll() { for c in live { c.sweep() } }
    static func cancelAll() async { for c in live { await c.cancelIndexing() } }
    static func resetAll() async {
        for c in live {
            await c.cancelIndexing()
            c.loadedIndexes.removeAll()
            c.failedIds.removeAll()
        }
    }

    static func clearIndexGlobally() async {
        await resetAll()
        EmbeddingStore.clearAll()
        sweepAll()
    }

    // MARK: - Triggers

    func projectOpened() {
        Log.search.notice(
            "index project opened enabled=\(VisualModelLoader.shared.enabled)",
            telemetry: "Search index project opened",
            data: ["enabled": VisualModelLoader.shared.enabled]
        )
        Task {
            await VisualModelLoader.shared.prepare()
            sweep()
        }
    }

    /// Enqueue all current assets that need (re)indexing.
    /// Failed assets get a fresh chance; failedIds only dedupes within a batch.
    func sweep() {
        guard VisualModelLoader.shared.enabled, VisualModelLoader.shared.isReady else { return }
        failedIds.removeAll()
        let assets = assetsProvider()
        Log.search.notice(
            "index sweep assets=\(assets.count) queuedBefore=\(queue.count)",
            telemetry: "Search index sweep",
            data: [
                "assets": assets.count,
                "ready": VisualModelLoader.shared.isReady,
                "queuedBefore": queue.count
            ]
        )
        for asset in assets {
            schedule(asset)
        }
    }

    func schedule(_ asset: MediaAsset) {
        guard !isCancelling,
              VisualModelLoader.shared.enabled,
              let model = VisualModelLoader.shared.embedder,
              !asset.isGenerating else { return }
        guard !scheduledIds.contains(asset.id), !failedIds.contains(asset.id) else { return }
        let snapshot = Self.snapshot(asset)
        queue.append(IndexWork(asset: snapshot, spec: model.spec))
        scheduledIds.insert(snapshot.id)
        batchTotal += 1
        ensureWorker()
    }

    nonisolated static func preflight(_ request: PreflightRequest) -> PreflightResult {
        let needsVisual = (request.type == .video || request.type == .image)
            && VisualIndexer.needsIndex(url: request.url, spec: request.spec)
        let needsTranscript = (request.type == .audio || (request.type == .video && request.hasAudio))
            && !TranscriptCache.hasCachedOnDisk(for: request.url)
        return PreflightResult(needsVisual: needsVisual, needsTranscript: needsTranscript)
    }

    private func cancelIndexing() async {
        isCancelling = true
        defer { isCancelling = false }
        let current = worker
        workerGeneration += 1
        worker = nil
        queue.removeAll()
        scheduledIds.removeAll()
        resetBatch()
        current?.cancel()
        await current?.value
        resetBatch()
    }

    private static func snapshot(_ asset: MediaAsset) -> AssetSnapshot {
        AssetSnapshot(
            id: asset.id,
            url: asset.url,
            type: asset.type,
            duration: asset.duration,
            hasAudio: asset.hasAudio,
            isGenerating: asset.isGenerating
        )
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        Log.search.notice(
            "index worker start generation=\(generation) depth=\(queue.count)",
            telemetry: "Search index worker started",
            data: ["generation": generation, "queueDepth": queue.count, "batchTotal": batchTotal]
        )
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, let work = self.dequeue() {
                self.currentAssetFraction = 0
                await self.process(work)
            }
            if let self, self.workerGeneration == generation {
                self.worker = nil
            }
        }
    }

    private func dequeue() -> IndexWork? {
        guard !queue.isEmpty else {
            resetBatch()
            return nil
        }
        return queue.removeFirst()
    }

    private func process(_ work: IndexWork) async {
        var retry: MediaAsset?
        defer {
            scheduledIds.remove(work.asset.id)
            batchCompleted += 1
            if let retry { schedule(retry) }
        }

        let request = PreflightRequest(
            url: work.asset.url,
            type: work.asset.type,
            hasAudio: work.asset.hasAudio,
            spec: work.spec
        )
        let task = Task.detached(priority: .utility) { Self.preflight(request) }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return }

        guard isCurrent(work) else {
            retry = assetsProvider().first { $0.id == work.asset.id }
            return
        }
        guard result.needsIndex else { return }

        while ExportQueue.shared.isExportActive, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        guard isCurrent(work), let model = VisualModelLoader.shared.embedder else {
            retry = assetsProvider().first { $0.id == work.asset.id }
            return
        }
        await indexOne(work.asset, model: model, transcribe: result.needsTranscript)
    }

    private func isCurrent(_ work: IndexWork) -> Bool {
        guard VisualModelLoader.shared.enabled,
              VisualModelLoader.shared.embedder?.spec == work.spec,
              let asset = assetsProvider().first(where: { $0.id == work.asset.id }) else { return false }
        return Self.snapshot(asset) == work.asset
    }

    private func resetBatch() {
        batchTotal = 0
        batchCompleted = 0
        currentAssetFraction = 0
    }

    private func indexOne(
        _ asset: AssetSnapshot,
        model: VisualEmbedder,
        transcribe: Bool
    ) async {
        let visualShare = transcribe ? 0.5 : 1.0
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.currentAssetFraction = fraction * visualShare }
        }
        let url = asset.url
        let isVideo = asset.type == .video
        let start = ContinuousClock.now
        do {
            async let transcriptDone: Void = {
                if transcribe {
                    try await ExportQueue.shared.waitWhileExportActive()
                    _ = try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: nil)
                }
            }()
            switch asset.type {
            case .image:
                try await VisualIndexer.indexImage(url: url, model: model)
            case .video:
                try await VisualIndexer.index(
                    url: url, duration: asset.duration, model: model, progress: onProgress
                )
            default:
                break
            }
            loadedIndexes[asset.id] = nil
            let visualSeconds = start.duration(to: .now).seconds
            currentAssetFraction = visualShare
            try await transcriptDone
            let totalSeconds = start.duration(to: .now).seconds
            Log.search.debug("""
                indexed \(asset.id.prefix(8)) visual=\(String(format: "%.1f", visualSeconds))s \
                total=\(String(format: "%.1f", totalSeconds))s transcribed=\(transcribe)
                """)
        } catch is CancellationError {
            Log.search.debug("index cancelled asset=\(asset.id.prefix(8)) type=\(asset.type.rawValue)")
        } catch {
            failedIds.insert(asset.id)
            Log.search.warning("index failed asset=\(asset.id.prefix(8)): \(error.localizedDescription)")
        }
    }

    // MARK: - Query

    func search(query: String, limit: Int = 20, within ids: Set<String>? = nil) async -> [VisualSearch.Hit] {
        guard let model = VisualModelLoader.shared.embedder, VisualModelLoader.shared.isReady else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Snapshot on main; stat/SHA256/file reads, encode, and ranking happen off-actor.
        let candidates = assetsProvider()
            .filter { ($0.type == .video || $0.type == .image) && (ids?.contains($0.id) ?? true) }
            .map { ($0.id, $0.url) }
        let cached = loadedIndexes
        let minScore = SearchIndexConfig.visualMatchCosineFloor

        let (hits, loaded) = await Task.detached(priority: .userInitiated) {
            var indexes: [(String, EmbeddingStore.AssetIndex)] = []
            var loaded: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]
            for (assetID, url) in candidates {
                guard let key = EmbeddingStore.key(for: url) else { continue }
                if let hit = cached[assetID], hit.key == key {
                    indexes.append((assetID, hit.index))
                } else if let index = try? EmbeddingStore.load(key: key) {
                    loaded[assetID] = (key, index)
                    indexes.append((assetID, index))
                }
            }
            guard !indexes.isEmpty, let vector = try? model.encode(text: trimmed) else {
                return ([VisualSearch.Hit](), loaded)
            }
            return (VisualSearch.search(query: vector, indexes: indexes, limit: limit, minScore: minScore), loaded)
        }.value

        loadedIndexes.merge(loaded) { _, new in new }
        return hits
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
