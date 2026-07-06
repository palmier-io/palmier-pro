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

    static func childTimeline() -> Timeline {
        CompositorFixtures.timeline([Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()])])
    }

    static func nestClip(for child: Timeline, start: Int = 0) -> Clip {
        Clip(
            mediaRef: child.id, mediaType: .sequence, sourceClipType: .sequence,
            startFrame: start, durationFrames: child.totalFrames
        )
    }

    @Test func nestedPatternMatchesDirectRender() async throws {
        let child = Self.childTimeline()
        let parent = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [Self.nestClip(for: child)])])

        let f = try await CompositorRenderTests.render(parent, frame: 15, timelines: [child, parent])
        #expect(isRed(f.tl), "TL \(f.tl)")
        #expect(isWhite(f.br), "BR \(f.br)")
    }

    @Test func nestOpacityDimsWholeGroup() async throws {
        let child = Self.childTimeline()
        var nest = Self.nestClip(for: child)
        nest.opacity = 0.5
        let parent = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [nest])])

        let f = try await CompositorRenderTests.render(parent, frame: 15, timelines: [child, parent])
        // White quadrant at 50% over black ≈ mid grey.
        let br = f.br
        #expect(br.r > 80 && br.r < 170, "BR should be dimmed white: \(br)")
    }

    @Test func nestTransformScalesGroupAsUnit() async throws {
        let child = Self.childTimeline()
        var nest = Self.nestClip(for: child)
        nest.transform = Transform(centerX: 0.25, centerY: 0.25, width: 0.5, height: 0.5)
        let parent = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [nest])])

        let f = try await CompositorRenderTests.render(parent, frame: 15, timelines: [child, parent])
        #expect(isBlack(f.at(300, 170)), "outside the scaled nest should be black: \(f.at(300, 170))")
        #expect(isRed(f.at(20, 10)), "nest TL quadrant lands top-left: \(f.at(20, 10))")
    }

    @Test func nestOffsetInTimeShowsBlackBeforeStart() async throws {
        let child = Self.childTimeline()
        let parent = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [Self.nestClip(for: child, start: 30)])])

        let before = try await CompositorRenderTests.render(parent, frame: 15, timelines: [child, parent])
        #expect(isBlack(before.center), "before the nest starts: \(before.center)")
        let during = try await CompositorRenderTests.render(parent, frame: 45, timelines: [child, parent])
        #expect(isRed(during.tl), "nest content at frame 45: \(during.tl)")
    }

    @Test func nestSegmentsScopeDecoderDemand() async throws {
        // Child: clip A on track 1 for [0,30), clip B on track 2 for [30,60).
        // The nest must not require both source tracks across its whole span.
        let child = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "a", duration: 30)]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "b", start: 30, duration: 30)])
        ])
        let parent = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [{
            var nest = Self.nestClip(for: child)
            nest.durationFrames = 60
            return nest
        }()])])

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
        let middle = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [Self.nestClip(for: grandchild)])])
        let parent = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [Self.nestClip(for: middle)])])

        let f = try await CompositorRenderTests.render(parent, frame: 15, timelines: [grandchild, middle, parent])
        #expect(isRed(f.tl), "TL through two nest levels: \(f.tl)")
        #expect(isWhite(f.br), "BR through two nest levels: \(f.br)")
    }
}

private let isRed = CompositorFixtures.isRed
private let isWhite = CompositorFixtures.isWhite
private let isBlack = CompositorFixtures.isBlack
