import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

/// End-to-end smoke test for the AVFoundation-backed video export path.
///
/// Slow (~1–2s) — runs a real AVAssetExportSession against a black-video fixture generated
/// by `ImageVideoGenerator.blackVideo`. Catches the worst-case "exported file is corrupt or
/// missing" bug. Pure-logic tests for the input math live in CompositionBuilderTests and
/// ExportResolutionTests.
@Suite("ExportService — round-trip")
@MainActor
struct ExportServiceRoundTripTests {

    @Test func h264ExportProducesPlayableMp4ContainingVideoTrack() async throws {
        // 1. Generate fixture via production code path.
        let renderSize = CGSize(width: 320, height: 180)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)

        // 2. Manifest + resolver point at the fixture file.
        let mediaRef = "black-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef, name: "black", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 5.0
        )]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        // 3. Tiny timeline: one 1-second clip at 30fps.
        let clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, start: 0, duration: 30)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = Int(renderSize.width)
        timeline.height = Int(renderSize.height)

        // 4. Export to a temp .mp4.
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let svc = ExportService()
        await svc.export(
            timeline: timeline, resolver: resolver,
            format: .h264, resolution: .r720p,
            outputURL: outURL
        )

        // 5. Verify success state on the service.
        #expect(svc.error == nil, "export reported error: \(svc.error ?? "")")
        #expect(svc.progress == 1.0)
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        // 6. Round-trip: load the exported file and verify it's a real video.
        let asset = AVURLAsset(url: outURL)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)
        // Approximately 1 second (the clip we exported). Tolerance for encoder rounding.
        #expect(abs(duration.seconds - 1.0) < 0.5,
                "expected ~1s exported, got \(duration.seconds)s")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!videoTracks.isEmpty, "exported file has no video tracks")
    }
}
