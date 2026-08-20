import CoreMedia
import Foundation
import Testing
@testable import PalmierPro

@Suite("Mask point mapping")
struct MaskPointMapperTests {
    private let trim = TrimmedSource(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        trimStartFrame: 30,
        trimEndFrame: 0,
        sourceFramesConsumed: 120,
        fps: 30
    )

    @Test func mapsSourceTimeAndCoordinatesToSegment() throws {
        let prompt = try MaskPointMapper.map(
            MaskPointSeed(
                x: 0.5,
                y: 0.25,
                sourceTime: MaskSourceTime(CMTime(seconds: 2, preferredTimescale: 600))
            ),
            trim: trim,
            segmentWidth: 1920,
            segmentHeight: 1080,
            segmentFPS: 24,
            segmentFrameCount: 96
        )
        #expect(prompt == SegmentPointPrompt(x: 960, y: 270, frameIndex: 24))
    }

    @Test func sourceTimeAccountsForTrimAndSpeed() throws {
        var clip = Clip(mediaRef: "media", startFrame: 100, durationFrames: 60)
        clip.trimStartFrame = 30
        clip.speed = 1.5
        let time = try MaskPointMapper.sourceTime(
            clip: clip,
            timelineFrame: 120,
            timelineFPS: 30
        )
        #expect(abs(time.cmTime.seconds - 2) < 0.000_001)
    }

    @Test func mapsNormalizedEdgesInsideLastPixel() throws {
        let prompt = try MaskPointMapper.map(
            MaskPointSeed(
                x: 1,
                y: 1,
                sourceTime: MaskSourceTime(CMTime(seconds: 4.99, preferredTimescale: 600))
            ),
            trim: trim,
            segmentWidth: 1920,
            segmentHeight: 1080,
            segmentFPS: 24,
            segmentFrameCount: 96
        )
        #expect(prompt.x == 1919)
        #expect(prompt.y == 1079)
        #expect(prompt.frameIndex == 95)
    }

    @Test(arguments: [
        MaskPointSeed(x: -0.01, y: 0.5, sourceTime: MaskSourceTime(.zero)),
        MaskPointSeed(x: 0.5, y: 1.01, sourceTime: MaskSourceTime(.zero)),
        MaskPointSeed(x: .nan, y: 0.5, sourceTime: MaskSourceTime(.zero)),
    ])
    func rejectsInvalidCoordinates(seed: MaskPointSeed) {
        #expect(throws: MaskPointMapper.MappingError.invalidCoordinates) {
            try MaskPointMapper.map(
                seed,
                trim: trim,
                segmentWidth: 1920,
                segmentHeight: 1080,
                segmentFPS: 24,
                segmentFrameCount: 96
            )
        }
    }

    @Test func rejectsSourceTimeOutsideVisibleRange() {
        #expect(throws: MaskPointMapper.MappingError.sourceTimeOutOfRange) {
            try MaskPointMapper.map(
                MaskPointSeed(
                    x: 0.5,
                    y: 0.5,
                    sourceTime: MaskSourceTime(CMTime(seconds: 5, preferredTimescale: 600))
                ),
                trim: trim,
                segmentWidth: 1920,
                segmentHeight: 1080,
                segmentFPS: 24,
                segmentFrameCount: 96
            )
        }
    }
}
