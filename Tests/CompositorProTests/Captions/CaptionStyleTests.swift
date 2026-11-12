import Foundation
import Testing
@testable import CompositorPro

@Suite("Caption styles")
struct CaptionStyleTests {
    @Test func registryHasUniqueIdsAcrossThreeGroups() {
        let ids = CaptionStyles.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count >= 30)
        for group in CaptionStyle.Group.allCases {
            #expect(CaptionStyles.all.contains { $0.group == group })
        }
    }

    @Test func resolvedStylesUseBundledFontsAndFiniteValues() throws {
        let bundled = Set(["Anton", "BasementGrotesque", "BebasNeue", "Caveat", "DMSans", "Geist",
                           "GeistMono", "Inter", "PermanentMarker", "PlayfairDisplay", "Poppins",
                           "Shrikhand", "SpaceGrotesk"])
        for style in CaptionStyles.all {
            #expect(bundled.contains(style.fontName), "\(style.id) uses unbundled font \(style.fontName)")
            let resolved = style.resolved(canvasHeight: 1080)
            #expect(resolved.style.fontSize.isFinite && resolved.style.fontSize >= 12 && resolved.style.fontSize <= 300)
            #expect(resolved.center.x.isFinite && resolved.center.y.isFinite)
            #expect((0.05...0.95).contains(resolved.center.y))
            #expect(resolved.style.color.r.isFinite && resolved.style.color.g.isFinite && resolved.style.color.b.isFinite)
        }
        #expect(try #require(CaptionStyles.preset(id: "subtitle")).animationPreset == TextAnimation.Preset.none)
        #expect(try #require(CaptionStyles.preset(id: "karaoke")).animationPreset == .wordSlide)
        #expect(CaptionStyles.preset(id: "missing") == nil)
    }

    @Test func projectFileRoundTripsCaptionStyle() throws {
        var file = ProjectFile(timelines: [Fixtures.timeline(tracks: [Fixtures.videoTrack()])])
        file.captionStyleId = "neon"
        let data = try JSONEncoder().encode(file)
        let back = try ProjectFile.decode(data)
        #expect(back.captionStyleId == "neon")
    }

    @Test func unknownStyleDropsToDefaultOnLoad() {
        var file = ProjectFile(timelines: [Fixtures.timeline(tracks: [Fixtures.videoTrack()])])
        file.captionStyleId = "deleted-style"
        // Mirror applyProjectFile's sanitizing: unknown ids resolve to default nil.
        let restored = file.captionStyleId.flatMap { CaptionStyles.preset(id: $0).map(\.id) }
        #expect(restored == nil)
    }
}

@Suite("add_captions captionStyle")
@MainActor
struct CaptionStyleToolTests {
    @Test func unknownStyleRefusesWithOptionList() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack()]))
        let result = await harness.runRaw("add_captions", args: ["captionStyle": "does-not-exist"])
        #expect(result.isError)
        let text = ToolHarness.textOf(result)
        #expect(text.contains("bold-pop"))
        #expect(text.contains("Choose one"))
    }

    @Test func styleAndAnimationComboRefuses() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack()]))
        let result = await harness.runRaw("add_captions", args: ["captionStyle": "neon", "animation": "popIn"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("captionStyle encodes"))
    }
}
