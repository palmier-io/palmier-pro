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
        let generation = cache.startVisualGeneration(key: "assetA", kind: .waveform)
        cache.invalidate("assetA")
        #expect(cache.commitWaveform([0, 1], key: "assetA", url: url, generation: generation) == false)
        #expect(cache.samples(for: "assetA") == nil)
    }

    @Test func currentGenerationCommitStoresWaveform() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/current-gen.wav")
        cache.knownAssetURLs["assetB"] = url
        let generation = cache.startVisualGeneration(key: "assetB", kind: .waveform)
        #expect(cache.commitWaveform([0.5, 0.25], key: "assetB", url: url, generation: generation))
        #expect(cache.samples(for: "assetB") == [0.5, 0.25])
    }

    @Test func urlMismatchCommitIsRejected() {
        let cache = MediaVisualCache()
        let oldURL = URL(fileURLWithPath: "/tmp/relink-old.wav")
        let newURL = URL(fileURLWithPath: "/tmp/relink-new.wav")
        cache.knownAssetURLs["assetC"] = newURL
        let generation = cache.startVisualGeneration(key: "assetC", kind: .waveform)
        #expect(cache.commitWaveform([0.5], key: "assetC", url: oldURL, generation: generation) == false)
        #expect(cache.samples(for: "assetC") == nil)
    }

    @Test func resetSessionStateRejectsLateCommits() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/reset-late.wav")
        cache.knownAssetURLs["assetD"] = url
        let generation = cache.startVisualGeneration(key: "assetD", kind: .waveform)
        cache.resetSessionState()
        #expect(cache.commitWaveform([0.5], key: "assetD", url: url, generation: generation) == false)
        #expect(cache.samples(for: "assetD") == nil)
    }

    @Test func imageCommitRejectsStaleGenerationAndStoresCurrent() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/image-commit.png")
        cache.knownAssetURLs["img"] = url
        let generation = cache.startVisualGeneration(key: "img", kind: .imageThumbnail)
        let image = makeDummyImage()
        #expect(cache.commitImageThumbnail(image, key: "img", url: url, generation: generation))
        #expect(cache.imageThumbnail(for: "img") === image)
        cache.invalidate("img")
        #expect(cache.imageThumbnail(for: "img") == nil)
    }

    @Test func videoThumbnailJobDoesNotInvalidateWaveformJob() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/cross-kind-waveform.wav")
        cache.knownAssetURLs["assetE"] = url
        let waveformGeneration = cache.startVisualGeneration(key: "assetE", kind: .waveform)
        // Filmstrips starting for the same video must not cancel the waveform job.
        let thumbnailGeneration = cache.startVisualGeneration(key: "assetE", kind: .videoThumbnails)

        #expect(cache.commitWaveform([0.25, 0.75], key: "assetE", url: url, generation: waveformGeneration))
        #expect(cache.samples(for: "assetE") == [0.25, 0.75])
        #expect(cache.commitVideoThumbnails([(0, makeDummyImage())], key: "assetE", url: url, generation: thumbnailGeneration))
        #expect(cache.thumbnails(for: "assetE")?.count == 1)
    }

    @Test func waveformJobDoesNotInvalidateVideoThumbnailJob() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/cross-kind-thumbs.mov")
        cache.knownAssetURLs["assetF"] = url
        let thumbnailGeneration = cache.startVisualGeneration(key: "assetF", kind: .videoThumbnails)
        let waveformGeneration = cache.startVisualGeneration(key: "assetF", kind: .waveform)

        #expect(cache.commitVideoThumbnails([(0, makeDummyImage())], key: "assetF", url: url, generation: thumbnailGeneration))
        #expect(cache.commitWaveform([0.5], key: "assetF", url: url, generation: waveformGeneration))
        #expect(cache.thumbnails(for: "assetF")?.count == 1)
        #expect(cache.samples(for: "assetF") == [0.5])
    }

    @Test func perKindGenerationStillRejectsStaleKindJob() {
        let cache = MediaVisualCache()
        let url = URL(fileURLWithPath: "/tmp/cross-kind-stale.wav")
        cache.knownAssetURLs["assetG"] = url
        let staleWaveform = cache.startVisualGeneration(key: "assetG", kind: .waveform)
        _ = cache.startVisualGeneration(key: "assetG", kind: .waveform)

        #expect(cache.commitWaveform([0.5], key: "assetG", url: url, generation: staleWaveform) == false)
        #expect(cache.samples(for: "assetG") == nil)
    }

    /// 25 visible filmstrips exceed the 24-asset limit; a pass must not evict what it is drawing.
    @Test func viewportDemandBeyondTheAssetLimitSurvivesConsecutivePasses() {
        let cache = MediaVisualCache()
        let image = makeDummyImage()
        let keys = (0..<25).map { "visible-\($0)" }
        for key in keys {
            let url = URL(fileURLWithPath: "/tmp/\(key).mov")
            cache.knownAssetURLs[key] = url
            let generation = cache.startVisualGeneration(key: key, kind: .videoThumbnails)
            #expect(cache.commitVideoThumbnails([(0, image)], key: key, url: url, generation: generation))
        }

        for pass in 0..<3 {
            cache.beginDisplayPass()
            for key in keys {
                #expect(cache.thumbnails(for: key) != nil, "pass \(pass) lost \(key)")
            }
            cache.endDisplayPass()
        }
    }

    @Test func assetsThatLeaveTheViewportAreEvictedAfterThePass() {
        let cache = MediaVisualCache()
        let image = makeDummyImage()
        let keys = (0..<25).map { "cold-\($0)" }
        for key in keys {
            let url = URL(fileURLWithPath: "/tmp/\(key).mov")
            cache.knownAssetURLs[key] = url
            let generation = cache.startVisualGeneration(key: key, kind: .videoThumbnails)
            #expect(cache.commitVideoThumbnails([(0, image)], key: key, url: url, generation: generation))
        }

        cache.beginDisplayPass()
        for key in keys {
            #expect(cache.thumbnails(for: key) != nil)
        }
        cache.endDisplayPass()

        // Same viewport again: nothing was evicted, so no filmstrip restarts decoding.
        cache.beginDisplayPass()
        for key in keys {
            #expect(cache.thumbnails(for: key) != nil, "second pass lost \(key)")
        }
        cache.endDisplayPass()

        // The viewport shrinks; only entries it no longer draws become evictable.
        cache.beginDisplayPass()
        for key in keys.prefix(3) {
            #expect(cache.thumbnails(for: key) != nil)
        }
        cache.endDisplayPass()

        #expect(cache.thumbnails(for: keys[3]) == nil)
        cache.beginDisplayPass()
        for key in keys.prefix(3) {
            #expect(cache.thumbnails(for: key) != nil)
        }
        cache.endDisplayPass()
    }
}

