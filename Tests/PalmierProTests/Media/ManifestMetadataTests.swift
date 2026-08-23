import Foundation
import Testing
@testable import PalmierPro
@MainActor struct ManifestMetadataTests {
    private func asset(_ id: String) -> MediaAsset {
        MediaAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id).mp4"), type: .video, name: id, duration: 1)
    }
    @Test func largeBatchUpdatesInPlace() {
        let editor = EditorViewModel()
        let assets = (0..<1_000).map { asset("asset-\($0)") }
        editor.updateManifestMetadata(for: assets)
        for (index, asset) in assets.enumerated() { asset.duration = Double(index) }
        editor.updateManifestMetadata(for: Array(assets.reversed()))
        #expect(editor.mediaManifest.entries[731].duration == 731)
    }
    @Test func queuedFlushUsesLatestLiveAssets() async {
        let editor = EditorViewModel()
        let renamed = asset("renamed")
        let deleted = asset("deleted")
        editor.mediaAssets = [renamed, deleted]
        editor.updateManifestMetadata(for: [renamed, deleted])
        editor.queueManifestMetadataUpdate(for: renamed)
        editor.queueManifestMetadataUpdate(for: deleted)
        renamed.name = "Latest"
        editor.mediaAssets = [renamed]
        editor.mediaManifest.entries.removeAll { $0.id == deleted.id }
        await editor.pendingManifestMetadataFlushTask?.value
        #expect(editor.mediaManifest.entries.map(\.name) == ["Latest"])
    }
    @Test func draftGenerationSurvivesManifestRoundTrip() throws {
        var input = GenerationInput(
            prompt: "Draft", model: "flux-3", duration: 8,
            aspectRatio: "16:9", resolution: "720p", draft: true
        )
        input.backendJobId = "draft-job"
        input.resultURLs = ["video", "cache"]
        let generated = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/draft.mp4"),
            type: .video,
            name: "Draft",
            generationInput: input
        )
        let data = try JSONEncoder().encode(generated.toManifestEntry(projectURL: nil))
        let restored = try JSONDecoder().decode(MediaManifestEntry.self, from: data)
        #expect(restored.generationInput?.draft == true)
        #expect(MediaAsset(entry: restored, resolvedURL: generated.url).canEnhanceDraft)
    }

    @Test func refundedCreditsSurviveManifestRoundTrip() throws {
        var input = GenerationInput(
            prompt: "Fail", model: "flux-3", duration: 5,
            aspectRatio: "16:9", resolution: "720p"
        )
        input.costCredits = 12
        input.refundedCredits = 12
        let generated = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/failed.mp4"),
            type: .video,
            name: "Failed",
            generationInput: input
        )
        generated.generationStatus = .failed("Provider error")
        let data = try JSONEncoder().encode(generated.toManifestEntry(projectURL: nil))
        let asset = MediaAsset(
            entry: try JSONDecoder().decode(MediaManifestEntry.self, from: data),
            resolvedURL: generated.url
        )
        #expect(asset.generationInput?.costCredits == 12)
        #expect(asset.generationInput?.refundedCredits == 12)
        #expect(asset.wasGenerationRefunded)
        asset.generationInput?.refundedCredits = 0
        #expect(!asset.wasGenerationRefunded)
    }
}
