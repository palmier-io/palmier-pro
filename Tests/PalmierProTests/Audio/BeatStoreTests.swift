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

    @Test func urlChangeRestartsHydrationWithCurrentURL() async throws {
        let loader = ControlledBeatCacheLoader()
        let store = makeStore(loader: loader)
        let originalURL = URL(fileURLWithPath: "/tmp/original.palmier/Media/audio.wav")
        let rebasedURL = URL(fileURLWithPath: "/tmp/rebased.palmier/Media/audio.wav")
        let asset = makeAsset(url: originalURL)
        let stale = BeatAnalysis(bpm: 90, beats: [0.5], downbeats: [])
        let current = BeatAnalysis(bpm: 120, beats: [1], downbeats: [1])

        let first = try #require(store.hydrate(for: asset))
        await loader.waitUntilInvocationCount(1)
        asset.url = rebasedURL
        #expect(await loader.finishNext(with: BeatAnalysisCacheEntry(analysis: stale, fileTag: "old")))
        await first.value

        await loader.waitUntilInvocationCount(2)
        let restarted = try #require(store.hydrate(for: asset))
        #expect(await loader.requestedURLs() == [originalURL, rebasedURL])
        #expect(store.analysis(for: asset.id) == nil)
        #expect(await loader.finishNext(with: BeatAnalysisCacheEntry(analysis: current, fileTag: "new")))
        await restarted.value

        #expect(store.analysis(for: asset.id) == current)
    }

    private func makeStore(loader: ControlledBeatCacheLoader) -> BeatStore {
        BeatStore { sourceURL, mediaRef in
            await loader.load(sourceURL: sourceURL, mediaRef: mediaRef)
        }
    }

    private func makeAsset(
        url: URL = URL(fileURLWithPath: "/tmp/beat-store-\(UUID().uuidString).wav")
    ) -> MediaAsset {
        MediaAsset(
            id: UUID().uuidString,
            url: url,
            type: .audio,
            name: "Test Audio"
        )
    }
}

private actor ControlledBeatCacheLoader {
    private var loadCount = 0
    private var sourceURLs: [URL] = []
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resultWaiters: [CheckedContinuation<BeatAnalysisCacheEntry?, Never>] = []

    func load(sourceURL: URL, mediaRef _: String) async -> BeatAnalysisCacheEntry? {
        loadCount += 1
        sourceURLs.append(sourceURL)
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            if loadCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                startedWaiters.append(waiter)
            }
        }
        return await withCheckedContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        await waitUntilInvocationCount(1)
    }

    func waitUntilInvocationCount(_ count: Int) async {
        guard loadCount < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func invocationCount() -> Int { loadCount }

    func requestedURLs() -> [URL] { sourceURLs }

    func finishNext(with result: BeatAnalysisCacheEntry?) -> Bool {
        guard !resultWaiters.isEmpty else { return false }
        resultWaiters.removeFirst().resume(returning: result)
        return true
    }
}
