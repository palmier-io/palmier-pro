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
}
