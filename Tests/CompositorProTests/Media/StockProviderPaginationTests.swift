import Foundation
import Testing
@testable import CompositorPro

private final class StockPaginationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let encoded = request.value(forHTTPHeaderField: "X-Stock-Fixture"),
              let data = Data(base64Encoded: encoded),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor OpenversePaginationRequests {
    private(set) var count = 0

    func record() { count += 1 }
}

struct StockProviderPaginationTests {
    private func request(_ json: String, page: Int, pageSizeKey: String, pageSize: Int) -> StockMediaJSONRequest {
        { url, headers in
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.first { $0.name == "page" }?.value == String(page))
            #expect(items.first { $0.name == pageSizeKey }?.value == String(pageSize))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StockPaginationURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue(Data(json.utf8).base64EncodedString(), forHTTPHeaderField: "X-Stock-Fixture")
            let (data, _) = try await session.data(for: request)
            return data
        }
    }

    private func query(kind: StockMediaKind, limit: Int = 1, page: Int = 4) -> StockMediaQuery {
        StockMediaQuery(text: "harbor", kind: kind, orientation: nil, maxDurationSeconds: nil, limit: limit, page: page)
    }

    @Test func pexelsVideoUsesRequestedPageAndParsesExplicitNextPage() async throws {
        let json = """
        {"page":4,"total_results":99,"next_page":"https://api.pexels.com/v1/videos/search?page=7&per_page=2","videos":[
          {"id":1,"duration":12,"video_files":[{"quality":"hd","file_type":"video/mp4","width":1920,"height":1080,"link":"https://example.org/one.mp4"}]},
          {"id":2,"duration":12,"video_files":[{"quality":"hd","file_type":"video/mp4","width":1920,"height":1080,"link":"https://example.org/two.mp4"}]}
        ]}
        """
        let provider = PexelsProvider(apiKey: "offline-fixture", requestJSON: request(json, page: 4, pageSizeKey: "per_page", pageSize: 2))
        let page = try await provider.search(query(kind: .video))
        #expect(page.hits.map(\.id) == ["pexels-video-1", "pexels-video-2"])
        #expect(page.nextPage == 7)
        #expect(page.totalResults == 99)
    }

    @Test func pexelsPhotoAbsenceOfNextPageMeansExhaustion() async throws {
        let json = """
        {"page":4,"total_results":4,"photos":[
          {"id":3,"width":1920,"height":1080,"src":{"large2x":"https://example.org/three.jpg"}}
        ]}
        """
        let provider = PexelsProvider(apiKey: "offline-fixture", requestJSON: request(json, page: 4, pageSizeKey: "per_page", pageSize: 2))
        let page = try await provider.search(query(kind: .image))
        #expect(page.hits.map(\.id) == ["pexels-photo-3"])
        #expect(page.nextPage == nil)
        #expect(page.totalResults == 4)
    }

    @Test func pexelsFilteringAllRowsDoesNotEraseContinuation() async throws {
        let json = """
        {"page":4,"total_results":99,"next_page":"https://api.pexels.com/v1/videos/search?page=5","videos":[
          {"id":1,"duration":60,"video_files":[{"quality":"hd","file_type":"video/mp4","width":1920,"height":1080,"link":"https://example.org/one.mp4"}]}
        ]}
        """
        var query = query(kind: .video)
        query.maxDurationSeconds = 10
        let provider = PexelsProvider(apiKey: "offline-fixture", requestJSON: request(json, page: 4, pageSizeKey: "per_page", pageSize: 2))
        let page = try await provider.search(query)
        #expect(page.hits.isEmpty)
        #expect(page.nextPage == 5)
        #expect(page.totalResults == 99)
    }

    @Test(arguments: ["https://example.org/v1/videos/search?page=5", "https://api.pexels.com/v1/search?page=5",
                      "https://api.pexels.com/videos/search?page=5", "https://api.pexels.com/v1/videos/search?page=4",
                      "https://api.pexels.com/v1/videos/search?page=5&page=6", "https://api.pexels.com/v1/videos/search?page=invalid"])
    func malformedPexelsContinuationIsRefused(_ next: String) async {
        let json = """
        {"page":4,"total_results":99,"next_page":"\(next)","videos":[]}
        """
        let provider = PexelsProvider(apiKey: "offline-fixture", requestJSON: request(json, page: 4, pageSizeKey: "per_page", pageSize: 2))
        await #expect(throws: StockMediaError.undecodable(provider: "Pexels")) {
            _ = try await provider.search(query(kind: .video))
        }
    }

    @Test func pixabayUsesAccessibleTotalForContinuationNotFilteredCount() async throws {
        let json = """
        {"total":1000,"totalHits":13,"hits":[
          {"id":1,"duration":60,"videos":{"medium":{"url":"https://example.org/one.mp4","width":1920,"height":1080}}}
        ]}
        """
        var query = query(kind: .video)
        query.maxDurationSeconds = 10
        let provider = PixabayProvider(apiKey: "offline-fixture", requestJSON: request(json, page: 4, pageSizeKey: "per_page", pageSize: 3))
        let page = try await provider.search(query)
        #expect(page.hits.isEmpty)
        #expect(page.nextPage == 5)
        #expect(page.totalResults == 13)
    }

    @Test func pixabayStopsAtAccessibleTotalEvenWhenGlobalTotalIsLarger() async throws {
        let json = """
        {"total":1000,"totalHits":12,"hits":[
          {"id":1,"duration":12,"videos":{"medium":{"url":"https://example.org/one.mp4","width":1920,"height":1080}}},
          {"id":2,"duration":12,"videos":{"medium":{"url":"https://example.org/two.mp4","width":1920,"height":1080}}}
        ]}
        """
        let provider = PixabayProvider(apiKey: "offline-fixture", requestJSON: request(json, page: 4, pageSizeKey: "per_page", pageSize: 3))
        let page = try await provider.search(query(kind: .video))
        #expect(page.hits.count == 2)
        #expect(page.nextPage == nil)
        #expect(page.totalResults == 12)
    }

    @Test func openverseUsesOfficialPageCountAndReportedResults() async throws {
        let json = """
        {"page":4,"page_count":5,"page_size":2,"result_count":99,"results":[
          {"id":"first","url":"https://example.org/one.jpg","mature":false},
          {"id":"second","url":"https://example.org/two.jpg","mature":false}
        ]}
        """
        let provider = OpenverseProvider(requestJSON: request(json, page: 4, pageSizeKey: "page_size", pageSize: 2))
        let page = try await provider.search(query(kind: .image))
        #expect(page.hits.map(\.id) == ["openverse-first", "openverse-second"])
        #expect(page.nextPage == 5)
        #expect(page.totalResults == 99)
    }

    @Test(arguments: [
        (milliseconds: 1, maximum: 1, seconds: Int?.some(1)),
        (milliseconds: 500, maximum: 1, seconds: Int?.some(1)),
        (milliseconds: 999, maximum: 1, seconds: Int?.some(1)),
        (milliseconds: 1000, maximum: 1, seconds: Int?.some(1)),
        (milliseconds: 1001, maximum: 1, seconds: Int?.none),
        (milliseconds: 1999, maximum: 2, seconds: Int?.some(2)),
        (milliseconds: 2000, maximum: 2, seconds: Int?.some(2)),
        (milliseconds: 2001, maximum: 2, seconds: Int?.none),
        (milliseconds: 0, maximum: 1, seconds: Int?.none),
        (milliseconds: -1, maximum: 1, seconds: Int?.none),
        (milliseconds: Int.max, maximum: Int.max, seconds: Int?.some(Int.max / 1000 + 1)),
    ])
    func openverseAudioFiltersExactMillisecondsThenRoundsReceiptsUp(
        _ sample: (milliseconds: Int, maximum: Int, seconds: Int?)
    ) async throws {
        let json = """
        {"page":4,"page_count":4,"page_size":2,"result_count":2,"results":[
          {"id":"sample","url":"https://example.org/one.mp3","duration":\(sample.milliseconds),"mature":false},
          {"id":"missing","url":"https://example.org/two.mp3","mature":false}
        ]}
        """
        var query = query(kind: .audio)
        query.maxDurationSeconds = sample.maximum
        let provider = OpenverseProvider(requestJSON: request(json, page: 4, pageSizeKey: "page_size", pageSize: 2))
        let page = try await provider.search(query)
        #expect(page.hits.map(\.id) == (sample.seconds == nil ? [] : ["openverse-sample"]))
        #expect(page.hits.first?.durationSeconds == sample.seconds)
        #expect(page.nextPage == nil)
        #expect(page.totalResults == 2)
    }

    @Test(arguments: [1, 500, 999])
    func openverseSubsecondReceiptsRemainPositiveWithoutDurationFilter(_ milliseconds: Int) async throws {
        let json = """
        {"page":4,"page_count":4,"page_size":2,"result_count":1,"results":[
          {"id":"sample","url":"https://example.org/one.mp3","duration":\(milliseconds),"mature":false}
        ]}
        """
        let provider = OpenverseProvider(requestJSON: request(json, page: 4, pageSizeKey: "page_size", pageSize: 2))
        let page = try await provider.search(query(kind: .audio))
        #expect(page.hits.first?.durationSeconds == 1)
    }

    @Test(arguments: [StockMediaKind.image, .audio])
    func openverseAnonymousDepthAllowsPage12AndRefusesPage13BeforeHTTP(_ kind: StockMediaKind) async throws {
        let json = """
        {"page":12,"page_count":13,"page_size":20,"result_count":260,"results":[]}
        """
        let requests = OpenversePaginationRequests()
        let fixture = request(json, page: 12, pageSizeKey: "page_size", pageSize: 20)
        let provider = OpenverseProvider(requestJSON: { url, headers in
            await requests.record()
            #expect(headers.isEmpty)
            return try await fixture(url, headers)
        })
        let allowed = query(kind: kind, limit: 10, page: 12)
        #expect(OpenverseProvider.searchURL(allowed) != nil)
        let page = try await provider.search(allowed)
        #expect(page.nextPage == 13)
        #expect(await requests.count == 1)

        let denied = query(kind: kind, limit: 10, page: 13)
        #expect(OpenverseProvider.searchURL(denied) == nil)
        await #expect(throws: StockMediaError.invalidQuery(field: "openversePaginationDepth")) {
            _ = try await provider.search(denied)
        }
        let result = try await StockMediaSearch.collect(denied, providers: [provider])
        #expect(result.outcomes.first?.status == .failed)
        #expect(result.outcomes.first?.pagesFetched == 0)
        #expect(result.outcomes.first?.exhausted == false)
        #expect(await requests.count == 1)
    }

    @Test func openverseDepthRefusalRetainsPreviouslyFetchedPageAndContinuation() async throws {
        let json = """
        {"page":12,"page_count":13,"page_size":20,"result_count":260,"results":[
          {"id":"kept","url":"https://example.org/kept.jpg","mature":false}
        ]}
        """
        let requests = OpenversePaginationRequests()
        let fixture = request(json, page: 12, pageSizeKey: "page_size", pageSize: 20)
        let provider = OpenverseProvider(requestJSON: { url, headers in
            await requests.record()
            #expect(headers.isEmpty)
            return try await fixture(url, headers)
        })
        let result = try await StockMediaSearch.collect(query(kind: .image, limit: 10, page: 12), providers: [provider])
        #expect(result.hits.map(\.id) == ["openverse-kept"])
        #expect(result.outcomes.first?.status == .failed)
        #expect(result.outcomes.first?.pagesFetched == 1)
        #expect(result.outcomes.first?.nextPage == 13)
        #expect(result.outcomes.first?.exhausted == false)
        #expect(result.outcomes.first?.totalResults == 260)
        #expect(await requests.count == 1)
    }

    @Test(arguments: [(limit: 1, page: 120), (limit: 9, page: 13), (limit: 10, page: 12), (limit: 50, page: 12)])
    func openverseAnonymousDepthUsesActualPageSize(_ sample: (limit: Int, page: Int)) {
        #expect(OpenverseProvider.searchURL(query(kind: .image, limit: sample.limit, page: sample.page)) != nil)
        #expect(OpenverseProvider.searchURL(query(kind: .image, limit: sample.limit, page: sample.page + 1)) == nil)
    }

    @Test func openverseFilteredEmptyPageStillHasContinuation() async throws {
        let json = """
        {"page":4,"page_count":5,"page_size":2,"result_count":99,"results":[
          {"id":"first","url":"https://example.org/one.jpg","mature":true}
        ]}
        """
        let provider = OpenverseProvider(requestJSON: request(json, page: 4, pageSizeKey: "page_size", pageSize: 2))
        let page = try await provider.search(query(kind: .image))
        #expect(page.hits.isEmpty)
        #expect(page.nextPage == 5)
    }

    @Test func directProvidersRejectInvalidQueryBeforeRequestOrCredentials() async {
        let request: StockMediaJSONRequest = { _, _ in
            Issue.record("Invalid queries must not make HTTP requests.")
            throw URLError(.badURL)
        }
        let providers: [any StockMediaProvider] = [
            OpenverseProvider(requestJSON: request), PexelsProvider(apiKey: "", requestJSON: request),
            PixabayProvider(apiKey: "", requestJSON: request),
        ]
        for provider in providers {
            await #expect(throws: StockMediaError.invalidQuery(field: "limit")) {
                _ = try await provider.search(query(kind: .video, limit: Int.max))
            }
        }
    }

    @Test(arguments: [1, 50])
    func providerPageSizesRespectAPILimitsWithoutClampingUserLimit(_ limit: Int) throws {
        let video = query(kind: .video, limit: limit, page: 500)
        let image = query(kind: .image, limit: limit, page: 12)
        let urls = [try #require(PixabayProvider.searchURL(video, key: "offline-fixture")),
                    try #require(PexelsProvider.searchURL(video)), try #require(OpenverseProvider.searchURL(image))]
        let sizes = [max(3, limit * 2), min(80, limit * 2), min(20, limit * 2)]
        for (index, url) in urls.enumerated() {
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.first { $0.name == "page" }?.value == (index == 2 ? "12" : "500"))
            #expect(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == ["api/videos", "v1/videos/search", "v1/images"][index])
            #expect(items.first { $0.name == (index == 2 ? "page_size" : "per_page") }?.value == String(sizes[index]))
        }
    }
}
