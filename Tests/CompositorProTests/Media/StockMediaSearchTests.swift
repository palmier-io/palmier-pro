import Foundation
import Testing
@testable import CompositorPro

private func stockHit(_ id: String, provider: String = "fake", url: String? = nil) -> StockMediaHit {
    StockMediaHit(
        id: id, kind: .video, title: nil, url: url ?? "https://example.org/\(provider)/\(id).mp4",
        thumbnailURL: nil, creator: nil, creatorURL: nil, license: "CC0", licenseURL: nil,
        providerID: provider, landingPageURL: nil, width: 1920, height: 1080,
        durationSeconds: 12, fileSizeBytes: nil, attributionText: nil
    )
}

private actor StockSearchGate {
    private var entries = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait() async {
        entries += 1
        let ready = observers.filter { $0.0 <= entries }
        observers.removeAll { $0.0 <= entries }
        for (_, observer) in ready { observer.resume() }
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForEntries(_ count: Int) async {
        guard entries < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor StockSearchProvider: StockMediaProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let supportedKinds: Set<StockMediaKind>
    private let pages: [Int: Result<StockMediaPage, StockMediaError>]
    private let gate: StockSearchGate?
    private(set) var queries: [StockMediaQuery] = []

    init(
        id: String = "fake", kinds: Set<StockMediaKind> = [.video],
        pages: [Int: Result<StockMediaPage, StockMediaError>], gate: StockSearchGate? = nil
    ) {
        self.id = id
        displayName = id.capitalized
        supportedKinds = kinds
        self.pages = pages
        self.gate = gate
    }

    func search(_ query: StockMediaQuery) async throws -> StockMediaPage {
        queries.append(query)
        if let gate { await gate.wait() }
        guard let page = pages[query.page] else { throw StockMediaError.badStatus(provider: id, code: 500) }
        return try page.get()
    }
}

struct StockMediaSearchTests {
    private func query(limit: Int = 2, page: Int = 1, excluded: Set<String> = []) -> StockMediaQuery {
        StockMediaQuery(text: "  harbor\n", kind: .video, orientation: nil, maxDurationSeconds: nil,
                        limit: limit, page: page, excludedSourceIds: excluded)
    }

    @Test func paginationFillsAfterExclusionsAndAlternateURLs() async throws {
        let excluded = stockHit("excluded")
        let repeated = stockHit("repeated")
        let provider = StockSearchProvider(pages: [
            1: .success(.init(hits: [excluded, stockHit("excluded", url: "https://example.org/alternate.mp4"),
                                    repeated, stockHit("repeated", url: "https://example.org/rendition.mp4")],
                              nextPage: 2, totalResults: 100)),
            2: .success(.init(hits: [stockHit("new")], totalResults: 100)),
        ])
        let result = try await StockMediaSearch.collect(query(excluded: [excluded.origin.sourceId]), providers: [provider])
        #expect(result.hits.map(\.id) == ["repeated", "new"])
        #expect(result.query.text == "harbor")
        #expect(result.totals == [100])
        #expect(result.outcomes[0].count == 2)
        #expect(result.outcomes[0].pagesFetched == 2)
        #expect(result.outcomes[0].exhausted)
        #expect(result.outcomes[0].nextPage == nil)
        #expect(await provider.queries.map(\.page) == [1, 2])
    }

    @Test func finalLimitAppliesAfterFilteringEntirePage() async throws {
        let provider = StockSearchProvider(pages: [1: .success(.init(hits: [
            stockHit("excluded"), stockHit("first"), stockHit("second"),
        ]))])
        let result = try await StockMediaSearch.collect(query(limit: 1, excluded: ["stock:fake:excluded"]), providers: [provider])
        #expect(result.hits.map(\.id) == ["first"])
        #expect(result.outcomes[0].count == 2)
        #expect(await provider.queries.count == 1)
    }

    @Test func canonicalIdentityNotURLControlsDeduplication() async throws {
        let sharedURL = "https://example.org/shared.mp4"
        let provider = StockSearchProvider(pages: [1: .success(.init(hits: [
            stockHit("first", url: sharedURL), stockHit("first", url: "https://example.org/alternate.mp4"),
            stockHit("second", url: sharedURL),
        ]))])
        let result = try await StockMediaSearch.search(query(), providers: [provider])
        #expect(result.hits.map(\.id) == ["first", "second"])
    }

    @Test func sharedCanonicalSourceAcrossProvidersIsStillOneCandidate() async throws {
        let first = StockSearchProvider(id: "first", pages: [1: .success(.init(hits: [stockHit("shared")]))])
        let second = StockSearchProvider(id: "second", pages: [1: .success(.init(hits: [
            stockHit("shared", url: "https://example.org/alternate.mp4"), stockHit("new"),
        ]))])
        let result = try await StockMediaSearch.collect(query(), providers: [first, second])
        #expect(result.hits.map(\.id) == ["shared", "new"])
    }

    @Test func providersInterleaveInStableOrderWithTwoConcurrentWorkers() async throws {
        let gate = StockSearchGate()
        let providers = ["first", "second", "third"].map { id in
            StockSearchProvider(id: id, pages: [1: .success(.init(
                hits: (1...5).map { stockHit("\($0)", provider: id) }
            ))], gate: gate)
        }
        let task = Task { try await StockMediaSearch.collect(query(limit: 5), providers: providers) }
        await gate.waitForEntries(2)
        #expect(await providers[0].queries.count == 1)
        #expect(await providers[1].queries.count == 1)
        #expect(await providers[2].queries.isEmpty)
        await gate.release()
        let result = try await task.value
        #expect(result.hits.map { $0.origin.sourceId } == [
            "stock:first:1", "stock:second:1", "stock:third:1", "stock:first:2", "stock:second:2",
        ])
        #expect(result.outcomes.map(\.id) == ["first", "second", "third"])
    }

    @Test func enoughEligibleHitsPreserveUnfetchedContinuation() async throws {
        let provider = StockSearchProvider(pages: [1: .success(.init(hits: [stockHit("first")], nextPage: 7, totalResults: 50))])
        let result = try await StockMediaSearch.collect(query(limit: 1), providers: [provider])
        #expect(await provider.queries.map(\.page) == [1])
        #expect(result.outcomes[0].pagesFetched == 1)
        #expect(!result.outcomes[0].exhausted)
        #expect(result.outcomes[0].nextPage == 7)
        #expect(result.outcomes[0].totalResults == 50)
    }

    @Test func followsExplicitContinuationEvenForEmptyPages() async throws {
        let provider = StockSearchProvider(pages: [
            4: .success(.init(hits: [], nextPage: 7)),
            7: .success(.init(hits: [stockHit("new")])),
        ])
        let result = try await StockMediaSearch.collect(query(limit: 1, page: 4), providers: [provider])
        #expect(await provider.queries.map(\.page) == [4, 7])
        #expect(result.hits.map(\.id) == ["new"])
        #expect(result.outcomes[0].exhausted)
    }

    @Test func threePageQuotaDoesNotClaimExhaustionOrThrowEmptyVideoError() async throws {
        let provider = StockSearchProvider(pages: Dictionary(uniqueKeysWithValues: (1...3).map { page in
            (page, .success(StockMediaPage(hits: [stockHit("excluded")], nextPage: page + 1, totalResults: 99)))
        }))
        let exhausted = StockSearchProvider(id: "empty", pages: [1: .success(.init(hits: [], totalResults: 0))])
        let result = try await StockMediaSearch.search(query(excluded: ["stock:fake:excluded"]), providers: [provider, exhausted])
        #expect(result.hits.isEmpty)
        #expect(await provider.queries.map(\.page) == [1, 2, 3])
        #expect(result.outcomes[0].pagesFetched == 3)
        #expect(!result.outcomes[0].exhausted)
        #expect(result.outcomes[0].nextPage == 4)
        #expect(result.outcomes[1].exhausted)
        #expect(result.totalResults == 99)
    }

    @Test func pageBoundStopsWithoutDiscardingProviderContinuation() async throws {
        let provider = StockSearchProvider(pages: [500: .success(.init(hits: [], nextPage: 501, totalResults: 1000))])
        let result = try await StockMediaSearch.collect(query(page: 500), providers: [provider])
        #expect(await provider.queries.map(\.page) == [500])
        #expect(result.outcomes[0].nextPage == 501)
        #expect(!result.outcomes[0].exhausted)
    }

    @Test(arguments: [StockMediaError.rateLimited(provider: "fake"), .needsAPIKey(provider: "fake"), .badStatus(provider: "fake", code: 500)])
    func laterFailuresKeepPartialHitsTotalsAndFailedPageWithoutRetry(_ error: StockMediaError) async throws {
        let provider = StockSearchProvider(pages: [
            1: .success(.init(hits: [stockHit("first")], nextPage: 2, totalResults: 42)),
            2: .failure(error),
        ])
        let result = try await StockMediaSearch.collect(query(), providers: [provider])
        #expect(result.hits.map(\.id) == ["first"])
        #expect(result.totals == [42])
        #expect(result.outcomes[0].count == 1)
        #expect(result.outcomes[0].pagesFetched == 1)
        #expect(result.outcomes[0].nextPage == 2)
        #expect(!result.outcomes[0].exhausted)
        #expect(result.outcomes[0].status == (error == .rateLimited(provider: "fake") ? .rateLimited : error == .needsAPIKey(provider: "fake") ? .needsAPIKey : .failed))
        #expect(result.outcomes[0].message == error.errorDescription)
        #expect(await provider.queries.map(\.page) == [1, 2])
    }

    @Test func failedUnsupportedAndExhaustedOutcomesRemainDistinct() async throws {
        let failed = StockSearchProvider(id: "failed", pages: [1: .failure(.rateLimited(provider: "failed"))])
        let unsupported = StockSearchProvider(id: "unsupported", kinds: [.image], pages: [:])
        let empty = StockSearchProvider(id: "empty", pages: [1: .success(.init(hits: [], totalResults: 10))])
        let result = try await StockMediaSearch.search(query(), providers: [failed, unsupported, empty])
        #expect(result.hits.isEmpty)
        #expect(result.outcomes.map(\.status) == [.rateLimited, .unsupportedKind, .ok])
        #expect(result.outcomes.map(\.pagesFetched) == [0, 0, 1])
        #expect(result.outcomes.map(\.exhausted) == [false, false, true])
        #expect(await unsupported.queries.isEmpty)
    }

    @Test func exhaustedEmptyVideoSearchKeepsExistingRefusal() async {
        let provider = StockSearchProvider(pages: [1: .success(.init(hits: []))])
        await #expect(throws: StockMediaError.noUsableResults) {
            _ = try await StockMediaSearch.search(query(), providers: [provider])
        }
    }

    @Test func nonadvancingContinuationIsFailureNotRetryOrExhaustion() async throws {
        let provider = StockSearchProvider(pages: [1: .success(.init(hits: [stockHit("first")], nextPage: 1))])
        let result = try await StockMediaSearch.collect(query(), providers: [provider])
        #expect(result.outcomes[0].status == .failed)
        #expect(result.outcomes[0].pagesFetched == 0)
        #expect(!result.outcomes[0].exhausted)
        #expect(result.hits.isEmpty)
        #expect(await provider.queries.count == 1)
    }

    @Test func cancellationAfterProviderAwaitRejectsResultsAndQueuedProviders() async {
        let gate = StockSearchGate()
        let providers = ["first", "second", "third"].map {
            StockSearchProvider(id: $0, pages: [1: .success(.init(hits: [stockHit("first", provider: $0)]))], gate: gate)
        }
        let task = Task { try await StockMediaSearch.collect(query(), providers: providers) }
        await gate.waitForEntries(2)
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await providers[2].queries.isEmpty)
    }

    @Test func cancellationBeforeCollectMakesNoProviderRequest() async {
        let gate = StockSearchGate()
        let provider = StockSearchProvider(pages: [1: .success(.init(hits: []))])
        let task = Task {
            await gate.wait()
            return try await StockMediaSearch.collect(query(), providers: [provider])
        }
        await gate.waitForEntries(1)
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await provider.queries.isEmpty)
    }

    @Test func cancelledProviderFailureIsNotReturnedAsPartialSuccess() async {
        let gate = StockSearchGate()
        let provider = StockSearchProvider(pages: [1: .failure(.rateLimited(provider: "fake"))], gate: gate)
        let task = Task { try await StockMediaSearch.collect(query(), providers: [provider]) }
        await gate.waitForEntries(1)
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test(arguments: [Int.min, -1, 0, 51, Int.max])
    func invalidLimitIsRefusedWithoutProviderWork(_ limit: Int) async {
        let provider = StockSearchProvider(pages: [:])
        await #expect(throws: StockMediaError.invalidQuery(field: "limit")) {
            _ = try await StockMediaSearch.collect(query(limit: limit), providers: [provider])
        }
        #expect(await provider.queries.isEmpty)
    }

    @Test(arguments: [Int.min, -1, 0, 501, Int.max])
    func invalidPageIsRefused(_ page: Int) throws {
        #expect(throws: StockMediaError.invalidQuery(field: "page")) { try query(page: page).normalized() }
    }

    @Test(arguments: [Int.min, -1, 0])
    func durationMustBePositive(_ duration: Int) throws {
        var query = query()
        query.maxDurationSeconds = duration
        #expect(throws: StockMediaError.invalidQuery(field: "maxDurationSeconds")) { try query.normalized() }
    }

    @Test func unsupportedDurationAndOrientationAreRefused() throws {
        var query = query()
        query.kind = .image
        query.maxDurationSeconds = 1
        #expect(throws: StockMediaError.invalidQuery(field: "maxDurationSeconds")) { try query.normalized() }
        query.maxDurationSeconds = nil
        query.kind = .audio
        query.orientation = "landscape"
        #expect(throws: StockMediaError.invalidQuery(field: "orientation")) { try query.normalized() }
        query.kind = .video
        query.orientation = "horizontal"
        #expect(throws: StockMediaError.invalidQuery(field: "orientation")) { try query.normalized() }
    }

    @Test(arguments: ["", "media:asset", "sha256:abc", "stock::asset", "stock:fake:", "stock:Fake:asset",
                      "stock:fake:asset:extra", "stock:fake:with space", "stock:fake:with\nnewline", "stock:fake:é",
                      "stock:fake:/file", "stock:fake:" + String(repeating: "x", count: 256)])
    func malformedCanonicalExclusionsAreRefused(_ sourceId: String) throws {
        #expect(throws: StockMediaError.invalidQuery(field: "excludedSourceIds")) {
            try query(excluded: [sourceId]).normalized()
        }
    }

    @Test func derivedExclusionsRemainCompleteBeyondExplicitToolLimit() throws {
        let ids = Set((1...256).map { "stock:fake:asset-\($0)" })
        var query = query(limit: 50, page: 500, excluded: ids)
        query.maxDurationSeconds = Int.max
        #expect(try query.normalized().excludedSourceIds == ids)
        query.excludedSourceIds.insert("stock:fake:extra")
        #expect(try query.normalized().excludedSourceIds == ids.union(["stock:fake:extra"]))
    }

    @Test func canonicalSourceIdUTF8BoundIsInclusive() throws {
        let sourceId = "stock:fake:" + String(repeating: "x", count: 245)
        #expect(sourceId.utf8.count == 256)
        #expect(try query(excluded: [sourceId]).normalized().excludedSourceIds == [sourceId])
        #expect(throws: StockMediaError.invalidQuery(field: "excludedSourceIds")) {
            try query(excluded: [sourceId + "x"]).normalized()
        }
    }

    @Test func receiptReportsQuotaAndProviderTotal() {
        let outcome = StockProviderOutcome(id: "fake", displayName: "Fake", status: .ok, count: 2, message: nil,
                                           pagesFetched: 3, exhausted: false, nextPage: 4, totalResults: 100)
        #expect(outcome.receipt["pagesFetched"] as? Int == 3)
        #expect(outcome.receipt["exhausted"] as? Bool == false)
        #expect(outcome.receipt["nextPage"] as? Int == 4)
        #expect(outcome.receipt["totalResults"] as? Int == 100)
    }
}
