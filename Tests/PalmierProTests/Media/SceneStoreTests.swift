import Foundation
import Testing
@testable import PalmierPro

@Suite("SceneStore")
@MainActor
struct SceneStoreTests {
    @Test func hydrationReturnsWhileCacheLoadIsPending() async throws {
        let loader = ControlledSceneCacheLoader()
        let store = makeStore(loader: loader)
        let asset = makeAsset()

        let task = try #require(store.hydrate(for: asset))
        await loader.waitUntilStarted()

        #expect(store.analysis(for: asset.id) == nil)
        #expect(await loader.invocationCount() == 1)
        #expect(await loader.finishNext(with: nil))
        await task.value
    }

    @Test func invalidationRejectsLateHydrationResult() async throws {
        let loader = ControlledSceneCacheLoader()
        let store = makeStore(loader: loader)
        let asset = makeAsset()
        let analysis = SceneAnalysis(cuts: [1.5], duration: 4)

        let task = try #require(store.hydrate(for: asset))
        await loader.waitUntilStarted()
        store.invalidate(asset.id)
        #expect(await loader.finishNext(with: SceneAnalysisCacheEntry(analysis: analysis, fileTag: "tag")))
        await task.value

        #expect(store.analysis(for: asset.id) == nil)
    }

    @Test func urlChangeRestartsHydrationWithCurrentURL() async throws {
        let loader = ControlledSceneCacheLoader()
        let store = makeStore(loader: loader)
        let originalURL = URL(fileURLWithPath: "/tmp/original.palmier/Media/clip.mov")
        let rebasedURL = URL(fileURLWithPath: "/tmp/rebased.palmier/Media/clip.mov")
        let asset = makeAsset(url: originalURL)
        let stale = SceneAnalysis(cuts: [0.5], duration: 3)
        let current = SceneAnalysis(cuts: [1], duration: 3)

        let first = try #require(store.hydrate(for: asset))
        await loader.waitUntilInvocationCount(1)
        asset.url = rebasedURL
        #expect(await loader.finishNext(with: SceneAnalysisCacheEntry(analysis: stale, fileTag: "old")))
        await first.value

        await loader.waitUntilInvocationCount(2)
        let restarted = try #require(store.hydrate(for: asset))
        #expect(await loader.requestedURLs() == [originalURL, rebasedURL])
        #expect(store.analysis(for: asset.id) == nil)
        #expect(await loader.finishNext(with: SceneAnalysisCacheEntry(analysis: current, fileTag: "new")))
        await restarted.value

        #expect(store.analysis(for: asset.id) == current)
    }

    private func makeStore(loader: ControlledSceneCacheLoader) -> SceneStore {
        SceneStore(cachedAnalysisLoader: { sourceURL, mediaRef in
            await loader.load(sourceURL: sourceURL, mediaRef: mediaRef)
        })
    }

    private func makeAsset(
        url: URL = URL(fileURLWithPath: "/tmp/scene-store-\(UUID().uuidString).mov")
    ) -> MediaAsset {
        MediaAsset(
            id: UUID().uuidString,
            url: url,
            type: .video,
            name: "Test Video"
        )
    }
}

private actor ControlledSceneCacheLoader {
    private var loadCount = 0
    private var sourceURLs: [URL] = []
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resultWaiters: [CheckedContinuation<SceneAnalysisCacheEntry?, Never>] = []

    func load(sourceURL: URL, mediaRef _: String) async -> SceneAnalysisCacheEntry? {
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

    func finishNext(with result: SceneAnalysisCacheEntry?) -> Bool {
        guard !resultWaiters.isEmpty else { return false }
        resultWaiters.removeFirst().resume(returning: result)
        return true
    }
}
