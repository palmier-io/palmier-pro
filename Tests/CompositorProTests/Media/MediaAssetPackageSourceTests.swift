import Foundation
import Testing
@testable import CompositorPro

@Suite("Media asset package source boundaries")
@MainActor
struct MediaAssetPackageSourceTests {
    @Test(arguments: [
        ("/isolated/Proof.palmier/media/input.mov", "media/input.mov"),
        ("/isolated/Proof.palmier-archive/media/input.mov", nil),
        ("/isolated/Proof.palmier2/media/input.mov", nil),
        ("/isolated/Proof.palmier", nil),
        ("/isolated/other/input.mov", nil),
    ] as [(String, String?)])
    func onlyPackageDescendantsBecomeRelative(path: String, relativePath: String?) {
        let package = URL(fileURLWithPath: "/isolated/Proof.palmier", isDirectory: true)
        let asset = MediaAsset(url: URL(fileURLWithPath: path), type: .video, name: "Input")
        let expected: MediaSource = relativePath.map { .project(relativePath: $0) } ?? .external(absolutePath: path)
        #expect(asset.toManifestEntry(projectURL: package).source == expected)
        #expect(asset.url.path == path)
    }
}
