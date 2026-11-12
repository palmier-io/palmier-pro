import AppKit
import Testing
@testable import CompositorPro

@MainActor
@Suite("MediaVisualCache")
struct MediaVisualCacheTests {
    private func makeDummyImage() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 4, height: 4,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!
        return ctx.makeImage()!
    }

    @Test func resetSessionStateDropsAllVisuals() {
        let cache = MediaVisualCache()
        let assetA = MediaAsset(id: "assetA", url: URL(fileURLWithPath: "/tmp/a.mov"), type: .video, name: "A.mov", duration: 1.0)
        cache.generateWaveform(for: assetA)

        cache.resetSessionState()
        #expect(cache.samples(for: "assetA") == nil)
        #expect(cache.thumbnails(for: "assetA") == nil)
        #expect(cache.imageThumbnail(for: "assetA") == nil)
    }

    @Test func invalidateRemovesOnlyTargetVisuals() {
        let cache = MediaVisualCache()
        cache.invalidate("nonExistent")
        #expect(cache.samples(for: "nonExistent") == nil)
    }
}

