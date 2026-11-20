import Foundation
import Testing
@testable import CompositorPro

@Suite("export_project delivery")
@MainActor
struct ExportProjectDeliveryTests {
    private func harness(canvas: CGSize) -> ToolHarness {
        var timeline = Fixtures.timeline()
        timeline.width = Int(canvas.width)
        timeline.height = Int(canvas.height)
        timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(
            id: "v", mediaRef: "vid", mediaType: .video, start: 0, duration: 30
        )])]
        let harness = ToolHarness(timeline: timeline)
        harness.addAsset(id: "vid", type: .video, duration: 1)
        return harness
    }

    @Test("A delivery preset fills the codec and resolution, and reports the size")
    func presetFillsGaps() async throws {
        let harness = harness(canvas: CGSize(width: 1080, height: 1920))
        let receipt = try #require(
            try await harness.runOK("export_project", args: ["delivery": "tiktokShorts"])
                as? [String: Any]
        )
        #expect(receipt["format"] as? String == VideoCodec.h264.rawValue)
        #expect(receipt["deliveredSize"] as? String == "1080x1920")
        let notes = try #require(receipt["deliveryNotes"] as? [String])
        #expect(notes.contains { $0.contains("tiktokShorts") })
    }

    @Test("A matched canvas reports no orientation problem")
    func matchedCanvasIsQuiet() async throws {
        let harness = harness(canvas: CGSize(width: 1080, height: 1920))
        let receipt = try #require(
            try await harness.runOK("export_project", args: ["delivery": "instagramReels"])
                as? [String: Any]
        )
        let notes = receipt["deliveryNotes"] as? [String] ?? []
        #expect(!notes.contains { $0.contains("landscape") })
    }

    @Test("A mismatched canvas is reported rather than silently letterboxed")
    func mismatchIsReported() async throws {
        let harness = harness(canvas: CGSize(width: 1920, height: 1080))
        let receipt = try #require(
            try await harness.runOK("export_project", args: ["delivery": "tiktokShorts"])
                as? [String: Any]
        )
        let notes = try #require(receipt["deliveryNotes"] as? [String])
        #expect(notes.contains { $0.contains("landscape") })
    }

    @Test("An explicit resolution wins over the preset, and the receipt says so")
    func explicitResolutionWins() async throws {
        let harness = harness(canvas: CGSize(width: 1080, height: 1920))
        let receipt = try #require(
            try await harness.runOK("export_project", args: [
                "delivery": "tiktokShorts", "resolution": "720p",
            ]) as? [String: Any]
        )
        #expect(receipt["deliveredSize"] as? String == "720x1280", "explicit size wins")
        let notes = receipt["deliveryNotes"] as? [String] ?? []
        #expect(
            !notes.contains { $0.contains("chose") },
            "the receipt must not claim the preset chose when the caller did"
        )
    }

    @Test("An explicit codec wins too")
    func explicitCodecWins() async throws {
        let harness = harness(canvas: CGSize(width: 1920, height: 1080))
        let receipt = try #require(
            try await harness.runOK("export_project", args: [
                "delivery": "youtube", "codec": "ProRes",
            ]) as? [String: Any]
        )
        #expect(receipt["format"] as? String == VideoCodec.prores.rawValue)
    }

    @Test("No delivery still behaves exactly as before")
    func deliveryIsOptional() async throws {
        let harness = harness(canvas: CGSize(width: 1920, height: 1080))
        let receipt = try #require(
            try await harness.runOK("export_project") as? [String: Any]
        )
        #expect(receipt["format"] as? String == VideoCodec.h264.rawValue)
        #expect(receipt["deliveredSize"] as? String == "1920x1080")
    }

    @Test("An unknown platform is refused, and nothing is enqueued")
    func unknownPlatformRefused() async throws {
        let harness = harness(canvas: CGSize(width: 1080, height: 1920))
        let before = harness.exportQueue.jobs.count
        let result = await harness.runRaw("export_project", args: ["delivery": "instagram"])
        #expect(result.isError)
        #expect(harness.exportQueue.jobs.count == before)
    }

    @Test("delivery is rejected on a non-video mode rather than ignored")
    func rejectedForNonVideoMode() async throws {
        let harness = harness(canvas: CGSize(width: 1080, height: 1920))
        let result = await harness.runRaw("export_project", args: [
            "mode": "fcpxml", "delivery": "youtube",
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("video mode"))
    }

    @Test("A mistyped delivery key is rejected")
    func unknownKeyRefused() async throws {
        let harness = harness(canvas: CGSize(width: 1080, height: 1920))
        let result = await harness.runRaw("export_project", args: ["deliveryy": "youtube"])
        #expect(result.isError)
    }
}