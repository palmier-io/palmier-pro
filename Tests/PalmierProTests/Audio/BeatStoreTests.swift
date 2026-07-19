import Foundation
import Testing
@testable import PalmierPro

@Suite("BeatStore hydration")
@MainActor
struct BeatStoreTests {
    @Test func hydrationReturnsWhileCacheLoadIsPending() async throws {
        let loader = ControlledBeatCacheLoader()
        let store = makeStore(loader: loader)
        let asset = makeAsset()

        let task = try #require(store.hydrate(for: asset))
        await loader.waitUntilStarted()

        #expect(store.analysis(for: asset.id) == nil)
        #expect(await loader.invocationCount() == 1)
        #expect(await loader.finishNext(with: nil))
        await task.value
    }

    @Test func repeatedHydrationStartsOneCacheLoad() async throws {
        let loader = ControlledBeatCacheLoader()
        let store = makeStore(loader: loader)
        let asset = makeAsset()

        let first = try #require(store.hydrate(for: asset))
        let second = try #require(store.hydrate(for: asset))
        await loader.waitUntilStarted()

        #expect(await loader.invocationCount() == 1)
        #expect(await loader.finishNext(with: nil))
        await first.value
        await second.value
    }

    @Test func invalidationRejectsLateHydrationResult() async throws {
        let loader = ControlledBeatCacheLoader()
        let store = makeStore(loader: loader)
        let asset = makeAsset()
        let analysis = BeatAnalysis(bpm: 120, beats: [0.5], downbeats: [0.5])

        let task = try #require(store.hydrate(for: asset))
        await loader.waitUntilStarted()
        store.invalidate(asset.id)
        #expect(await loader.finishNext(with: BeatAnalysisCacheEntry(analysis: analysis, fileTag: "tag")))
        await task.value

        #expect(store.analysis(for: asset.id) == nil)
    }

    private func makeStore(loader: ControlledBeatCacheLoader) -> BeatStore {
        BeatStore { sourceURL, mediaRef in
            await loader.load(sourceURL: sourceURL, mediaRef: mediaRef)
        }
    }

    private func makeAsset() -> MediaAsset {
        MediaAsset(
            id: UUID().uuidString,
            url: URL(fileURLWithPath: "/tmp/beat-store-\(UUID().uuidString).wav"),
            type: .audio,
            name: "Test Audio"
        )
    }
}

private actor ControlledBeatCacheLoader {
    private var loadCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters: [CheckedContinuation<BeatAnalysisCacheEntry?, Never>] = []

    func load(sourceURL _: URL, mediaRef _: String) async -> BeatAnalysisCacheEntry? {
        loadCount += 1
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard loadCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func invocationCount() -> Int { loadCount }

    func finishNext(with result: BeatAnalysisCacheEntry?) -> Bool {
        guard !resultWaiters.isEmpty else { return false }
        resultWaiters.removeFirst().resume(returning: result)
        return true
    }
}
