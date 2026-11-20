import Foundation
import Testing
@testable import CompositorPro

private struct ShotCandidateExclusionProvider: StockMediaProvider {
    let id = "pexels"
    let displayName = "Fixture"
    let supportedKinds: Set<StockMediaKind> = [.video]

    func search(_ query: StockMediaQuery) async throws -> StockMediaPage {
        #expect(query.excludedSourceIds == ["stock:pexels:used"])
        #expect(query.excludedSourceIds.allSatisfy { $0.hasPrefix("stock:") })
        let hits = ["used", "alternative"].map { id in
            StockMediaHit(id: id, kind: .video, title: id, url: "https://example.test/\(id).mp4",
                thumbnailURL: nil, creator: "Creator", creatorURL: nil, license: "CC0", licenseURL: nil,
                providerID: "pexels", landingPageURL: nil, width: 1920, height: 1080,
                durationSeconds: 10, fileSizeBytes: nil, attributionText: "Creator, CC0")
        }
        return StockMediaPage(hits: hits, nextPage: nil, totalResults: 2)
    }
}

@MainActor
struct ShotCandidateRemoteExclusionTests {
    @Test func selectedLocalOriginExcludesRemoteTopHitWithoutRetargetingPlan() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(id: "selected")
        asset.inputIdentity = .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 100)
        asset.importInput = MediaImportInput(origin: .init(provider: "pexels", assetId: "used", landingPageURL: nil))
        harness.editor.mediaManifest.entries = [asset.toManifestEntry(projectURL: nil)]
        let plan = EditPlan(id: "board", name: "Board", timelineId: harness.editor.activeTimelineId,
            fps: 30, width: 1920, height: 1080, status: .approved,
            shots: [.init(id: "shot", title: "Selected", startFrame: 0, endFrame: 30, mediaRef: asset.id)])
        harness.editor.editPlans = [plan]
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let timeline = harness.editor.timeline
        let manifest = harness.editor.mediaManifest
        let executor = ToolExecutor(editor: harness.editor, exportQueue: harness.exportQueue,
            stockProviders: [ShotCandidateExclusionProvider()])
        let result = await executor.execute(name: "find_shot_candidates", args: [
            "query": "harbor", "kind": "video", "includeLibrary": false, "planId": "board", "limit": 1,
        ])
        #expect(!result.isError)
        let receipt = try #require(JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any])
        let candidates = try #require(receipt["candidates"] as? [[String: Any]])
        #expect(candidates.count == 1)
        #expect(candidates.first?["candidateId"] as? String == "stock:pexels:alternative")
        #expect(candidates.first?["license"] as? String == "CC0")
        #expect(receipt["noOp"] as? Bool == true)
        #expect(harness.editor.editPlans == [plan])
        #expect(harness.editor.mediaManifest == manifest)
        #expect(harness.editor.timeline == timeline)
        #expect(!undo.canUndo)
    }
}
