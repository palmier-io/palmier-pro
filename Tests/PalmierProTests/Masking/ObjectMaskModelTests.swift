import CoreMedia
import Foundation
import Testing
@testable import PalmierPro

@Suite("ObjectMask model")
struct ObjectMaskModelTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func maskRoundTripsThroughJSON() throws {
        let mask = ObjectMask(
            seed: .text("dog"),
            inverted: true,
            feather: 4.5,
            expansion: -2,
            removesBackground: true,
            track: MaskTrack(
                id: "track-1",
                mediaRef: "media-1",
                fps: 30,
                firstSourceFrame: 10,
                frameCount: 120
            )
        )
        #expect(try roundTrip(mask) == mask)
    }

    @Test func pointSeedRoundTripsThroughJSON() throws {
        let seed = MaskSeed.point(MaskPointSeed(
            x: 0.25,
            y: 0.75,
            sourceTime: MaskSourceTime(CMTime(value: 1_001, timescale: 600))
        ))
        #expect(try roundTrip(seed) == seed)
    }

    @Test func decodingToleratesMissingOptionalFields() throws {
        let json = #"{"seed": {"type": "text", "text": "dog"}}"#
        let mask = try JSONDecoder().decode(ObjectMask.self, from: Data(json.utf8))
        #expect(mask.seed == .text("dog"))
        #expect(mask.enabled)
        #expect(!mask.inverted)
        #expect(mask.feather == 0)
        #expect(mask.expansion == 0)
        #expect(!mask.removesBackground)
        #expect(mask.track == nil)
    }

    @Test func decodingRejectsUnknownSeedTypes() {
        let json = #"{"seed": {"type": "points", "points": []}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ObjectMask.self, from: Data(json.utf8))
        }
    }

    @Test func clipMasksSurviveProjectRoundTrip() throws {
        var clip = Clip(mediaRef: "media-1", startFrame: 0, durationFrames: 120)
        clip.masks = [ObjectMask(seed: .text("dog"))]
        let decoded = try roundTrip(clip)
        #expect(decoded.masks == clip.masks)
    }

    @Test func clipWithoutMasksDecodesAsNil() throws {
        let clip = Clip(mediaRef: "media-1", startFrame: 0, durationFrames: 120)
        let decoded = try roundTrip(clip)
        #expect(decoded.masks == nil)
    }

}
