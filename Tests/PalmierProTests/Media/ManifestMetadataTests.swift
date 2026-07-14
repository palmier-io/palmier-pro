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
}
