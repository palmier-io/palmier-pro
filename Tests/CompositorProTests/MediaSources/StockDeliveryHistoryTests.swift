import Foundation
import Testing
@testable import CompositorPro

@Suite("Stock delivery history", .serialized)
@MainActor
struct StockDeliveryHistoryTests {
    @Test("Bounded history caps entries at maximum limit")
    func capsEntriesAtMaximum() {
        var history = StockDeliveryHistory()
        for i in 0..<60 {
            history.add(sourceIds: ["source:\(i)"], outputFilename: "output_\(i).mp4")
        }
        #expect(history.entries.count == StockDeliveryHistory.maximumEntries)
        #expect(history.entries.last?.outputFilename == "output_59.mp4")
        #expect(!history.contains("source:0"))
        #expect(history.contains("source:59"))
    }

    @Test("Used sources union all entries")
    func usedSourcesUnion() {
        var history = StockDeliveryHistory()
        history.add(sourceIds: ["s1", "s2"], outputFilename: "video1.mp4")
        history.add(sourceIds: ["s2", "s3"], outputFilename: "video2.mp4")
        #expect(history.usedSourceIds == Set(["s1", "s2", "s3"]))
        #expect(history.contains("s1"))
        #expect(history.contains("s3"))
        #expect(!history.contains("s4"))
    }

    @Test("Loads and saves through UserDefaults")
    func persistsThroughDefaults() {
        StockDeliveryHistory.reset()
        var history = StockDeliveryHistory()
        history.add(sourceIds: ["s1"], outputFilename: "video1.mp4")
        history.save()

        let loaded = StockDeliveryHistory.load()
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries[0].outputFilename == "video1.mp4")
        #expect(loaded.usedSourceIds == Set(["s1"]))
        StockDeliveryHistory.reset()
        #expect(StockDeliveryHistory.load().entries.isEmpty)
    }

    @Test("Extracts canonical source IDs from media manifest")
    func extractsCanonicalSourceIds() {
        let origin = MediaImportOrigin(provider: "pexels", assetId: "12345", landingPageURL: nil)
        let entry = MediaManifestEntry(
            id: "clip-1",
            name: "Clip 1",
            type: .video,
            source: .project(relativePath: "media/clip-1.mp4"),
            duration: 5.0,
            importInput: MediaImportInput(origin: origin)
        )
        let manifest = MediaManifest(entries: [entry])

        #expect(StockDeliveryHistory.sourceIds(manifest: manifest) == Set(["media:clip-1", "stock:pexels:12345"]))
    }

    @Test("Empty manifest yields no IDs")
    func noManifestNoIds() {
        #expect(StockDeliveryHistory.sourceIds(manifest: MediaManifest()).isEmpty)
    }

    @Test("Resolver overload counts only clips the timeline resolved")
    func resolverOverloadCountsOnlyResolvedClips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolvedURL = dir.appendingPathComponent("resolved.mp4")
        try Data("fixture".utf8).write(to: resolvedURL)

        let entries = [
            MediaManifestEntry(
                id: "resolved",
                name: "Resolved",
                type: .video,
                source: .external(absolutePath: resolvedURL.path),
                duration: 5.0,
                importInput: MediaImportInput(
                    origin: MediaImportOrigin(provider: "pixabay", assetId: "777", landingPageURL: nil)
                )
            ),
            MediaManifestEntry(
                id: "offline",
                name: "Offline",
                type: .video,
                source: .external(absolutePath: dir.appendingPathComponent("missing.mp4").path),
                duration: 5.0,
                importInput: MediaImportInput(
                    origin: MediaImportOrigin(provider: "pixabay", assetId: "888", landingPageURL: nil)
                )
            ),
        ]
        let resolver = MediaResolver(manifest: { MediaManifest(entries: entries) }, projectURL: { nil })
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "c1", mediaRef: "resolved", start: 0, duration: 30),
                Fixtures.clip(id: "c2", mediaRef: "offline", start: 30, duration: 30),
                Fixtures.clip(id: "c3", mediaRef: "untouched", start: 60, duration: 30),
            ]),
        ])

        let ids = StockDeliveryHistory.sourceIds(resolver: resolver, timeline: timeline)
        #expect(ids == Set(["media:resolved", "stock:pixabay:777"]))
    }

    @Test("Resolver overload yields nothing for an empty timeline")
    func resolverOverloadEmptyTimeline() {
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { nil })
        #expect(StockDeliveryHistory.sourceIds(resolver: resolver, timeline: Fixtures.timeline()).isEmpty)
    }
}
