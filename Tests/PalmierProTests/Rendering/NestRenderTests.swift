import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

/// Pixel-level tests for live nested timelines: child clips composite through a
/// group layer, with the nest clip's transform/opacity applied to the unit.
@Suite("Compositor — nested timelines")
@MainActor
struct NestRenderTests {

    static let size = CompositorFixtures.renderSize  // 320×180

    static func render(
        _ timeline: Timeline, timelines: [Timeline], frame: Int
    ) async throws -> CompositorRenderTests.Frame {
        let pattern = try await CompositorFixtures.patternVideoURL()
        let byId = Dictionary(uniqueKeysWithValues: timelines.map { ($0.id, $0) })
        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "pattern" ? pattern : nil },
            resolveTimeline: { byId[$0] },
            renderSize: size
        )
        let gen = AVAssetImageGenerator(asset: result.composition)
        gen.videoComposition = result.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try await gen.image(
            at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))
        ).image
        return CompositorRenderTests.Frame(bytes: ColorProbeHelpers.srgbBytes(cg, size: size), w: Int(size.width))
    }

    static func childTimeline() -> Timeline {
        var child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()])])
        child.width = Int(size.width)
        child.height = Int(size.height)
        return child
    }

    static func nestClip(for child: Timeline, start: Int = 0) -> Clip {
        Clip(
            mediaRef: child.id, mediaType: .sequence, sourceClipType: .sequence,
            startFrame: start, durationFrames: child.totalFrames
        )
    }

    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 140 && p.g < 100 && p.b < 100 }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 170 && p.g > 170 && p.b > 170 }
    private func isBlack(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r < 45 && p.g < 45 && p.b < 45 }

    @Test func nestedPatternMatchesDirectRender() async throws {
        let child = Self.childTimeline()
        var parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Self.nestClip(for: child)])])
        parent.width = Int(Self.size.width)
        parent.height = Int(Self.size.height)

        let f = try await Self.render(parent, timelines: [child, parent], frame: 15)
        #expect(isRed(f.tl), "TL \(f.tl)")
        #expect(isWhite(f.br), "BR \(f.br)")
    }

    @Test func nestOpacityDimsWholeGroup() async throws {
        let child = Self.childTimeline()
        var nest = Self.nestClip(for: child)
        nest.opacity = 0.5
        var parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [nest])])
        parent.width = Int(Self.size.width)
        parent.height = Int(Self.size.height)

        let f = try await Self.render(parent, timelines: [child, parent], frame: 15)
        // White quadrant at 50% over black ≈ mid grey.
        let br = f.br
        #expect(br.r > 80 && br.r < 170, "BR should be dimmed white: \(br)")
    }

    @Test func nestTransformScalesGroupAsUnit() async throws {
        let child = Self.childTimeline()
        var nest = Self.nestClip(for: child)
        nest.transform = Transform(centerX: 0.25, centerY: 0.25, width: 0.5, height: 0.5)
        var parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [nest])])
        parent.width = Int(Self.size.width)
        parent.height = Int(Self.size.height)

        let f = try await Self.render(parent, timelines: [child, parent], frame: 15)
        #expect(isBlack(f.at(300, 170)), "outside the scaled nest should be black: \(f.at(300, 170))")
        #expect(isRed(f.at(20, 10)), "nest TL quadrant lands top-left: \(f.at(20, 10))")
    }

    @Test func nestOffsetInTimeShowsBlackBeforeStart() async throws {
        let child = Self.childTimeline()
        var parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Self.nestClip(for: child, start: 30)])])
        parent.width = Int(Self.size.width)
        parent.height = Int(Self.size.height)

        let before = try await Self.render(parent, timelines: [child, parent], frame: 15)
        #expect(isBlack(before.center), "before the nest starts: \(before.center)")
        let during = try await Self.render(parent, timelines: [child, parent], frame: 45)
        #expect(isRed(during.tl), "nest content at frame 45: \(during.tl)")
    }

    @Test func nestSegmentsScopeDecoderDemand() async throws {
        // Child: clip A on track 1 for [0,30), clip B on track 2 for [30,60).
        // The nest must not require both source tracks across its whole span.
        var child = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "a", duration: 30)]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "b", start: 30, duration: 30)])
        ])
        child.width = Int(Self.size.width)
        child.height = Int(Self.size.height)
        var parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [{
            var nest = Self.nestClip(for: child)
            nest.durationFrames = 60
            return nest
        }()])])
        parent.width = Int(Self.size.width)
        parent.height = Int(Self.size.height)

        let pattern = try await CompositorFixtures.patternVideoURL()
        let byId = Dictionary(uniqueKeysWithValues: [child, parent].map { ($0.id, $0) })
        let result = try await CompositionBuilder.build(
            timeline: parent,
            resolveURL: { _ in pattern },
            resolveTimeline: { byId[$0] },
            renderSize: Self.size
        )
        let counts = result.videoComposition.instructions
            .compactMap { $0 as? CompositorInstruction }
            .filter { !$0.layers.isEmpty }
            .map { $0.requiredSourceTrackIDs?.count ?? 0 }
        #expect(counts.max() == 1, "each nest segment should require one source track: \(counts)")
    }

    @Test func twoLevelNestRendersThrough() async throws {
        let grandchild = Self.childTimeline()
        var middle = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Self.nestClip(for: grandchild)])])
        middle.width = Int(Self.size.width)
        middle.height = Int(Self.size.height)
        var parent = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Self.nestClip(for: middle)])])
        parent.width = Int(Self.size.width)
        parent.height = Int(Self.size.height)

        let f = try await Self.render(parent, timelines: [grandchild, middle, parent], frame: 15)
        #expect(isRed(f.tl), "TL through two nest levels: \(f.tl)")
        #expect(isWhite(f.br), "BR through two nest levels: \(f.br)")
    }
}
