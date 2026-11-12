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

    @Test func videoThumbnailTimesCapCountForLongVideos() {
        let twoHours = MediaVisualCache.videoThumbnailTimes(duration: 7_200)
        #expect(twoHours.count <= MediaVisualCache.maxVideoThumbnailsPerAsset)
        #expect(!twoHours.isEmpty)
        #expect(twoHours.first?.seconds == 0)
        #expect(twoHours.last!.seconds < 7_200)
        #expect(MediaVisualCache.videoThumbnailTimes(duration: 5).count == 5)
        #expect(MediaVisualCache.videoThumbnailTimes(duration: 0).isEmpty)
        #expect(MediaVisualCache.videoThumbnailTimes(duration: -1).isEmpty)
        #expect(MediaVisualCache.videoThumbnailTimes(duration: .infinity).isEmpty)
    }

    @Test func diskCacheKeySeparatesThumbnailDensities() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaVisualCacheKey-\(UUID().uuidString).mov")
        try Data("stub".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let base = try #require(MediaVisualCache.diskCacheKey(for: url))
        #expect(base == MediaVisualCache.diskCacheKey(for: url))
        let dense = try #require(MediaVisualCache.diskCacheKey(for: url, thumbnailCount: 100))
        #expect(dense != base)
        #expect(dense == MediaVisualCache.diskCacheKey(for: url, thumbnailCount: 100))
        #expect(dense != MediaVisualCache.diskCacheKey(for: url, thumbnailCount: 200))
    }

    @Test func staleGenerationCommitIsRejected() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/stale-gen.wav")
        cache.knownAssetURLs["assetA"] = url
        let generation = cache.startVisualGeneration(key: "assetA")
        cache.invalidate("assetA")
        #expect(cache.commitWaveform([0, 1], key: "assetA", url: url, generation: generation) == false)
        #expect(cache.samples(for: "assetA") == nil)
    }

    @Test func currentGenerationCommitStoresWaveform() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/current-gen.wav")
        cache.knownAssetURLs["assetB"] = url
        let generation = cache.startVisualGeneration(key: "assetB")
        #expect(cache.commitWaveform([0.5, 0.25], key: "assetB", url: url, generation: generation))
        #expect(cache.samples(for: "assetB") == [0.5, 0.25])
    }

    @Test func urlMismatchCommitIsRejected() {
        let cache = MediaVisualCache()
        let oldURL = URL(fileURLWithPath: "/tmp/relink-old.wav")
        let newURL = URL(fileURLWithPath: "/tmp/relink-new.wav")
        cache.knownAssetURLs["assetC"] = newURL
        let generation = cache.startVisualGeneration(key: "assetC")
        #expect(cache.commitWaveform([0.5], key: "assetC", url: oldURL, generation: generation) == false)
        #expect(cache.samples(for: "assetC") == nil)
    }

    @Test func resetSessionStateRejectsLateCommits() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/reset-late.wav")
        cache.knownAssetURLs["assetD"] = url
        let generation = cache.startVisualGeneration(key: "assetD")
        cache.resetSessionState()
        #expect(cache.commitWaveform([0.5], key: "assetD", url: url, generation: generation) == false)
        #expect(cache.samples(for: "assetD") == nil)
    }

    @Test func imageCommitRejectsStaleGenerationAndStoresCurrent() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/image-commit.png")
        cache.knownAssetURLs["img"] = url
        let generation = cache.startVisualGeneration(key: "img")
        let image = makeDummyImage()
        #expect(cache.commitImageThumbnail(image, key: "img", url: url, generation: generation))
        #expect(cache.imageThumbnail(for: "img") === image)
        cache.invalidate("img")
        #expect(cache.imageThumbnail(for: "img") == nil)
    }
}

