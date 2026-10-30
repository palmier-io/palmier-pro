import Foundation
import Testing
@testable import PalmierPro

@Suite("search_media tool")
@MainActor
struct SearchMediaToolTests {
    @Test func rejectsBadArgs() async {
        let h = ToolHarness()
        #expect(await h.runRaw("search_media", args: [:]).isError)
        #expect(await h.runRaw("search_media", args: ["query": "  "]).isError)
        #expect(await h.runRaw("search_media", args: ["query": "a dog", "scope": "audio"]).isError)
        #expect(await h.runRaw("search_media", args: ["query": "a dog", "mediaRef": "nope"]).isError)
        #expect(await h.runRaw("search_media", args: ["query": "a dog", "bogus": 1]).isError)
    }

    @Test func spokenScopeReturnsOnlySpokenGroup() async throws {
        let h = ToolHarness()
        h.addAsset(type: .video)
        let obj = try await h.runOK("search_media", args: ["query": "budget", "scope": "spoken"]) as? [String: Any]
        #expect(obj?["spoken"] is [Any])
        #expect(obj?["moments"] == nil)
        #expect(obj?["status"] == nil)
    }

    @Test func restrictsToMediaRef() async throws {
        let h = ToolHarness()
        let a = h.addAsset(type: .video)
        h.addAsset(type: .video)
        let obj = try await h.runOK(
            "search_media", args: ["query": "budget", "scope": "spoken", "mediaRef": a.id]
        ) as? [String: Any]
        // No transcripts cached for stub URLs → empty, but the call resolves the ref.
        #expect((obj?["spoken"] as? [Any])?.isEmpty == true)
    }

    @Test func visualSearchInstallsMissingModelOnce() async throws {
        let model = VisualSearchModelStub()
        let h = ToolHarness(visualSearchModel: model)
        h.addAsset(type: .video)

        let first = try await h.runOK(
            "search_media", args: ["query": "a dog", "scope": "visual"]
        ) as? [String: Any]
        let second = try await h.runOK(
            "search_media", args: ["query": "a dog", "scope": "visual"]
        ) as? [String: Any]

        #expect(model.prepareCallCount == 1)
        #expect(model.downloadCallCount == 1)
        #expect((first?["index"] as? [String: Any])?["status"] as? String == "downloadingModel")
        #expect((second?["index"] as? [String: Any])?["status"] as? String == "downloadingModel")
        #expect((first?["index"] as? [String: Any])?["modelDownloadProgress"] as? Double == 0)
        #expect((second?["index"] as? [String: Any])?["modelDownloadProgress"] as? Double == 0)
    }

    @Test func visualSearchReportsFailedModelInstallWithoutRetrying() async throws {
        let model = VisualSearchModelStub(state: .failed("Connection lost"))
        let h = ToolHarness(visualSearchModel: model)
        h.addAsset(type: .video)

        let result = try await h.runOK(
            "search_media", args: ["query": "a dog", "scope": "visual"]
        ) as? [String: Any]
        let index = result?["index"] as? [String: Any]

        #expect(model.prepareCallCount == 0)
        #expect(model.downloadCallCount == 0)
        #expect(index?["status"] as? String == "failed")
        #expect(index?["modelDownloadProgress"] == nil)
        #expect(index?["modelDownloadError"] as? String == "Connection lost")
    }

    @Test func spokenSearchDoesNotInstallVisualModel() async throws {
        let model = VisualSearchModelStub()
        let h = ToolHarness(visualSearchModel: model)
        h.addAsset(type: .video)

        _ = try await h.runOK(
            "search_media", args: ["query": "budget", "scope": "spoken"]
        )

        #expect(model.prepareCallCount == 0)
        #expect(model.downloadCallCount == 0)
    }

    @Test func visualSearchWithoutVisualMediaDoesNotInstallModel() async throws {
        let model = VisualSearchModelStub()
        let h = ToolHarness(visualSearchModel: model)
        h.addAsset(type: .audio)

        let result = try await h.runOK(
            "search_media", args: ["query": "a dog", "scope": "visual"]
        ) as? [String: Any]

        #expect(model.prepareCallCount == 0)
        #expect(model.downloadCallCount == 0)
        #expect(result?["index"] == nil)
    }
}

@MainActor
private final class VisualSearchModelStub: VisualSearchModelLoading {
    var state: VisualModelLoader.State
    var enabled = true
    var embedder: VisualEmbedder? { nil }
    private(set) var prepareCallCount = 0
    private(set) var downloadCallCount = 0

    init(state: VisualModelLoader.State = .unknown) {
        self.state = state
    }

    func prepare() async {
        prepareCallCount += 1
        state = .notInstalled
    }

    func download() {
        downloadCallCount += 1
        state = .downloading(0)
    }
}
