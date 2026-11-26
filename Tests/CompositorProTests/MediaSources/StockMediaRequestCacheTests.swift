import Foundation
import Testing
@testable import CompositorPro

@Suite("Stock media request cache")
struct StockMediaRequestCacheTests {
    private let fm = FileManager.default

    private func makeCache(now: @escaping @Sendable () -> Date = { Date() }) -> StockMediaRequestCache {
        let directory = fm.temporaryDirectory.appendingPathComponent("stock-cache-\(UUID().uuidString)")
        return StockMediaRequestCache(cache: DiskCache(directory: directory), now: now)
    }

    private var query: StockMediaQuery {
        StockMediaQuery(text: "Harbor", kind: .video, limit: 3)
    }

    @Test func entriesExpireAfterTwentyFourHours() async {
        let clock = Clock(Date())
        let cache = makeCache(now: { clock.now })
        await cache.store(Data("payload".utf8), key: "pixabay|harbor")
        clock.now = Date()

        #expect(await cache.cachedResponse(key: "pixabay|harbor") == Data("payload".utf8))
        clock.now = clock.now.addingTimeInterval(StockMediaRequestCache.ttl - 60)
        #expect(await cache.cachedResponse(key: "pixabay|harbor") != nil)
        clock.now = clock.now.addingTimeInterval(120)
        #expect(await cache.cachedResponse(key: "pixabay|harbor") == nil)
    }

    @Test func keyIgnoresExcludedSourceIdsButSeparatesPages() {
        var first = query
        first.excludedSourceIds = ["pixabay-video-1"]
        var second = query
        second.excludedSourceIds = []
        #expect(StockMediaRequestCache.key(provider: "pixabay", query: first)
            == StockMediaRequestCache.key(provider: "pixabay", query: second))

        var nextPage = query
        nextPage.page = 2
        #expect(StockMediaRequestCache.key(provider: "pixabay", query: query)
            != StockMediaRequestCache.key(provider: "pixabay", query: nextPage))
        #expect(StockMediaRequestCache.key(provider: "pixabay", query: query)
            != StockMediaRequestCache.key(provider: "pexels", query: query))
    }

    @Test func repeatedProviderSearchUsesTheCachedResponse() async throws {
        let cache = makeCache()
        let counter = RequestCounter()
        let payload = Data("{\"hits\":[],\"totalHits\":0}".utf8)
        let provider = PixabayProvider(
            apiKey: "test-key",
            requestJSON: { _, _ in await counter.increment(); return payload },
            requestCache: cache
        )

        let first = try await provider.search(query)
        let second = try await provider.search(query)
        #expect(first.hits.isEmpty && second.hits.isEmpty)
        #expect(await counter.value == 1)
    }

    @Test func differentQueriesAreNotShared() async throws {
        let cache = makeCache()
        let counter = RequestCounter()
        let provider = PixabayProvider(
            apiKey: "test-key",
            requestJSON: { _, _ in await counter.increment(); return Data("{\"hits\":[],\"totalHits\":0}".utf8) },
            requestCache: cache
        )

        _ = try await provider.search(query)
        var other = query
        other.text = "Desert"
        _ = try await provider.search(other)
        #expect(await counter.value == 2)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private actor RequestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
