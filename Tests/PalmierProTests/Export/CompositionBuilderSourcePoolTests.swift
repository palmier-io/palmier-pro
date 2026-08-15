import AVFoundation
import Foundation
import os
import Testing
@testable import PalmierPro

@Suite("CompositionBuilder source pool")
struct CompositionBuilderSourcePoolTests {

    @Test func repeatedSourcesCreateOneAssetPerUniqueURL() async throws {
        let sourceURLs = try await makeVideoSources(count: 8)
        defer { sourceURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let mediaRefs = (0..<16).map { "source-\($0)" }
        let urlsByRef = Dictionary(uniqueKeysWithValues: mediaRefs.enumerated().map {
            ($0.element, sourceURLs[$0.offset % sourceURLs.count])
        })
        let timeline = makeTimeline(clipCount: 356, trackCount: 13, mediaRefs: mediaRefs)
        let assetCreations = OSAllocatedUnfairLock(initialState: 0)
        let started = ContinuousClock.now

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { urlsByRef[$0] },
            renderSize: CGSize(width: 320, height: 180),
            makeAsset: { url in
                assetCreations.withLock { $0 += 1 }
                return AVURLAsset(url: url)
            }
        )

        let elapsed = started.duration(to: .now)
        print("SOURCE_POOL_BENCHMARK clips=356 sources=8 elapsed=\(elapsed)")
        #expect(result.offlineMediaRefs.isEmpty)
        #expect(result.unprocessableMediaRefs.isEmpty)
        #expect(assetCreations.withLock { $0 } == sourceURLs.count)
    }

    @Test func transientTrackFailureDoesNotPoisonURLAliases() async throws {
        let sourceURL = try await makeVideoSource(index: 0)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let clips = [
            Fixtures.clip(id: "first", mediaRef: "first-ref", start: 0, duration: 6),
            Fixtures.clip(id: "second", mediaRef: "second-ref", start: 6, duration: 6),
        ]
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: clips)])
        let assetCreations = OSAllocatedUnfairLock(initialState: 0)
        let trackLoadAttempts = OSAllocatedUnfairLock(initialState: 0)

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { _ in sourceURL },
            renderSize: CGSize(width: 320, height: 180),
            makeAsset: { url in
                assetCreations.withLock { $0 += 1 }
                return AVURLAsset(url: url)
            },
            loadTracks: { asset, mediaType in
                let attempt = trackLoadAttempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if attempt == 1 { throw NSError(domain: "transient", code: 1) }
                return try await asset.loadTracks(withMediaType: mediaType)
            }
        )

        let insertedIds = result.trackMappings.reduce(into: Set<String>()) { ids, mapping in
            guard case .timeline(_, let clipIds) = mapping.kind, let clipIds else { return }
            ids.formUnion(clipIds)
        }
        #expect(assetCreations.withLock { $0 } == 1)
        #expect(trackLoadAttempts.withLock { $0 } == 2)
        #expect(result.offlineMediaRefs == ["first-ref"])
        #expect(insertedIds.contains("second"))
    }

    @Test func repeatedAlphaSourceUsesOneNormalizedAsset() async throws {
        let sourceURL = try await makeAlphaSource()
        let mediaRef = "alpha-\(UUID().uuidString)"
        let normalizedURL = ImageVideoGenerator.cacheDirectory.appendingPathComponent(
            "\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_premul.mov"
        )
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: normalizedURL)
        }
        let clips = [
            Fixtures.clip(id: "first", mediaRef: mediaRef, start: 0, duration: 15),
            Fixtures.clip(id: "second", mediaRef: mediaRef, start: 15, duration: 15),
        ]
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: clips)])
        let assetCreations = OSAllocatedUnfairLock(initialState: 0)

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { _ in sourceURL },
            renderSize: CGSize(width: 64, height: 64),
            makeAsset: { url in
                assetCreations.withLock { $0 += 1 }
                return AVURLAsset(url: url)
            }
        )

        #expect(result.offlineMediaRefs.isEmpty)
        #expect(assetCreations.withLock { $0 } == 2)
        #expect(FileManager.default.fileExists(atPath: normalizedURL.path))
    }

    @Test func cancellationStopsBeforeResolvingSources() async {
        let clip = Fixtures.clip(id: "clip", mediaRef: "source", start: 0, duration: 6)
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { _ in
                    resolutions.withLock { $0 += 1 }
                    return URL(fileURLWithPath: "/unused.mov")
                },
                renderSize: CGSize(width: 320, height: 180)
            )
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(resolutions.withLock { $0 } == 0)
    }

    private func makeVideoSources(count: Int) async throws -> [URL] {
        var urls: [URL] = []
        for index in 0..<count { urls.append(try await makeVideoSource(index: index)) }
        return urls
    }

    private func makeVideoSource(index: Int) async throws -> URL {
        try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (UInt8(truncatingIfNeeded: index * 20), 40, 80), seconds: 1)],
            fps: 30,
            size: 64,
            fileType: .mov
        )
    }

    private func makeTimeline(clipCount: Int, trackCount: Int, mediaRefs: [String]) -> Timeline {
        let baseCount = clipCount / trackCount
        let remainder = clipCount % trackCount
        var globalIndex = 0
        let tracks = (0..<trackCount).map { trackIndex in
            let count = baseCount + (trackIndex < remainder ? 1 : 0)
            let clips = (0..<count).map { localIndex in
                defer { globalIndex += 1 }
                return Fixtures.clip(
                    id: "clip-\(globalIndex)",
                    mediaRef: mediaRefs[globalIndex % mediaRefs.count],
                    start: localIndex * 6,
                    duration: 6
                )
            }
            return Fixtures.videoTrack(id: "track-\(trackIndex)", clips: clips)
        }
        return Fixtures.timeline(fps: 30, tracks: tracks)
    }

    private func makeAlphaSource() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let buffer = try alphaBuffer(pool: adaptor.pixelBufferPool)
        try #require(adaptor.append(buffer, withPresentationTime: .zero))
        try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: 29, timescale: 30)))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    private func alphaBuffer(pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 128, CVPixelBufferGetDataSize(pixelBuffer))
        return pixelBuffer
    }
}
