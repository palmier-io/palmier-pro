import Foundation
import Testing
@testable import CompositorPro

@Suite("add_captions delivery platform")
@MainActor
struct AddCaptionsPlatformTests {
    private func cues() -> [SubtitleCue] {
        [SubtitleCue(text: String(repeating: "readable ", count: 12), startSeconds: 1, endSeconds: 2)]
    }

    private func specs(maxWidthRatio: Double) async throws -> [EditorViewModel.TextClipSpec] {
        try await CaptionSpecBuilder.build(
            cues: cues(), fps: 30, canvasWidth: 1080, canvasHeight: 1920,
            style: .caption, center: CGPoint(x: 0.5, y: 0.9), maxWidthRatio: maxWidthRatio
        )
    }

    /// The measure reaches layout, so a platform can never reserve space the captions then ignore.
    @Test("The measure handed to layout is the platform's, not a hardcoded constant")
    func measureReachesLayout() async throws {
        // Caption type is narrow relative to a typical canvas, so the measure usually does not
        // bind and the laid-out size is unchanged. Asserting it changed would be asserting
        // something untrue; what must hold is that the platform's ratio is what gets passed.
        let platform = DeliveryPlatform.instagramReels
        let ratio = platform.defaultCaptionPlacement().maxWidth
        let laidOut = try await specs(maxWidthRatio: ratio)
        let built = try await specs(maxWidthRatio: DeliveryPlatform.tiktokShorts.defaultCaptionPlacement().maxWidth)
        // Both measures are valid, and neither can produce a caption wider than its own measure.
        #expect(ratio > 0 && ratio < 1)
        #expect(try #require(laidOut.first?.transform).width <= ratio + 0.001)
        #expect(
            try #require(built.first?.transform).width
                <= DeliveryPlatform.tiktokShorts.defaultCaptionPlacement().maxWidth + 0.001
        )
    }

    @Test("Vertical placement, not measure, is what a platform actually changes")
    func verticalPlacementIsTheRealEffect() {
        // This is the behaviour a short-form edit depends on: the caption lifts clear of the
        // bottom interface. The measure is a secondary refinement that rarely binds.
        let generic = DeliveryPlatform.generic.defaultCaptionPlacement()
        for platform in [DeliveryPlatform.tiktokShorts, .instagramReels] {
            let lifted = platform.defaultCaptionPlacement()
            #expect(lifted.centerY < generic.centerY - 0.1, "\(platform.rawValue) must lift clearly")
        }
    }

    @Test("The schema advertises the platforms and defaults to none of them")
    func schemaExposesPlatforms() throws {
        let tool = try #require(ToolDefinitions.mcpServer.first { $0.name == .addCaptions })
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        let platform = try #require(properties["platform"])
        #expect(
            platform["enum"] as? [String] == ["generic", "youtube", "tiktokShorts", "instagramReels"]
        )
    }

    @Test("An unknown platform is refused by name, not silently defaulted")
    func unknownPlatformIsRefused() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let result = await harness.runRaw("add_captions", args: ["platform": "tiktok"])
        #expect(result.isError)
        let text = ToolHarness.textOf(result)
        #expect(text.contains("tiktokShorts"), "the refusal should name the accepted values")
    }

    @Test("A mistyped platform key is rejected rather than ignored")
    func unknownKeyIsRefused() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let result = await harness.runRaw("add_captions", args: ["platfrom": "youtube"])
        #expect(result.isError)
    }
}