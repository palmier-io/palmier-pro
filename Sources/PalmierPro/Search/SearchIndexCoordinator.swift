import Foundation

/// Per-project indexing queue and search
@MainActor
@Observable
final class SearchIndexCoordinator {
    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    private(set) var currentAssetFraction: Double = 0

    var indexingActive: Bool { batchCompleted < batchTotal }
    var indexingProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchCompleted) + min(max(currentAssetFraction, 0), 1)) / Double(batchTotal))
    }

    var assetsProvider: () -> [MediaAsset] = { [] }

    private var queue: [String] = []
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

    // MARK: - Export pause (refcounted across windows)

    /// Counts in-flight exports across all windows; indexing pauses while any run.
    struct ExportPauseCounter {
        private(set) var count = 0
        var isActive: Bool { count > 0 }
        mutating func begin() { count += 1 }
        mutating func end() { count = max(0, count - 1) }
    }

    private static var exportPause = ExportPauseCounter()
    static var exportActive: Bool { exportPause.isActive }
    static func exportDidBegin() { exportPause.begin() }
    static func exportDidEnd() { exportPause.end() }

    static func waitWhileExportActive() async throws {
        while exportActive {
            try await Task.sleep(for: .seconds(2))
        }
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
        for asset in assetsProvider() {
            schedule(asset)
        }
    }

    func schedule(_ asset: MediaAsset) {
        guard VisualModelLoader.shared.enabled, let model = VisualModelLoader.shared.embedder, !asset.isGenerating else { return }
        guard !queue.contains(asset.id), !failedIds.contains(asset.id) else { return }
        let needsVisual = (asset.type == .video || asset.type == .image)
            && VisualIndexer.needsIndex(url: asset.url, spec: model.spec)
        let needsSpoken = Self.wantsTranscript(asset) && SpokenIndexer.needsIndex(url: asset.url)
        guard needsVisual || needsSpoken || needsTranscript(asset) else { return }
        queue.append(asset.id)
        batchTotal += 1
        ensureWorker()
    }

    static func wantsTranscript(_ asset: MediaAsset) -> Bool {
        asset.type == .audio || (asset.type == .video && asset.hasAudio)
    }

    private func needsTranscript(_ asset: MediaAsset) -> Bool {
        Self.wantsTranscript(asset) && !TranscriptCache.hasCachedOnDisk(for: asset.url)
    }

    /// Stops the worker and waits for the in-flight asset to actually stop.
    private func cancelIndexing() async {
        let current = worker
        workerGeneration += 1
        worker = nil
        queue.removeAll()
        resetBatch()
        current?.cancel()
        await current?.value
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, let asset = self.dequeue() {
                while Self.exportActive, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                }
                self.currentAssetFraction = 0
                await self.indexOne(asset)
            }
            if let self, self.workerGeneration == generation {
                self.worker = nil
            }
        }
    }

    private func dequeue() -> MediaAsset? {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let asset = assetsProvider().first(where: { $0.id == id }) { return asset }
            batchCompleted += 1
        }
        resetBatch()
        return nil
    }

    private func resetBatch() {
        batchTotal = 0
        batchCompleted = 0
        currentAssetFraction = 0
    }

    private func indexOne(_ asset: MediaAsset) async {
        defer { batchCompleted += 1 }
        guard let model = VisualModelLoader.shared.embedder else { return }
        let transcribe = needsTranscript(asset)
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
                    try await SearchIndexCoordinator.waitWhileExportActive()
                    _ = try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: nil)
                }
                try await SpokenIndexer.index(url: url)
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
            Log.search.notice("""
                indexed \(asset.id.prefix(8)) visual=\(String(format: "%.1f", visualSeconds))s \
                total=\(String(format: "%.1f", totalSeconds))s transcribed=\(transcribe)
                """)
        } catch is CancellationError {
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
