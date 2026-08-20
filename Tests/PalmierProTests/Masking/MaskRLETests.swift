import Foundation
import Testing
@testable import PalmierPro

@Suite("Mask RLE decoding")
struct MaskRLETests {
    // Prefix of a real provider frame (960x540 source): (start, length) pairs.
    private let realPrefix = "388 11 1348 13 2307 16 3266 17 4225 18 5184 19 6144 19"

    @Test func decodesRealProviderPairs() throws {
        let runs = try MaskRLE.runs(from: realPrefix, width: 960, height: 540)
        #expect(runs.count == 7)
        #expect(runs.first == MaskRLE.Run(start: 388, length: 11))
        let area = runs.reduce(0) { $0 + $1.length }
        #expect(area == 113)
    }

    @Test func emptyStringIsValidEmptyMask() throws {
        let runs = try MaskRLE.runs(from: "", width: 960, height: 540)
        #expect(runs.isEmpty)
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: MaskRLE.DecodeError.malformedToken) {
            try MaskRLE.runs(from: "10 abc", width: 100, height: 100)
        }
        #expect(throws: MaskRLE.DecodeError.oddPairCount) {
            try MaskRLE.runs(from: "10 5 20", width: 100, height: 100)
        }
        #expect(throws: MaskRLE.DecodeError.nonPositiveLength) {
            try MaskRLE.runs(from: "10 0", width: 100, height: 100)
        }
        #expect(throws: MaskRLE.DecodeError.overlappingRuns) {
            try MaskRLE.runs(from: "10 5 12 3", width: 100, height: 100)
        }
        #expect(throws: MaskRLE.DecodeError.malformedToken) {
            try MaskRLE.runs(from: "-4 5", width: 100, height: 100)
        }
    }

    @Test func clampsProviderOffByOneAtFrameEnd() throws {
        // Real provider bug: final run ends exactly one pixel past the area.
        let runs = try MaskRLE.runs(from: "9999 2", width: 100, height: 100)
        #expect(runs == [MaskRLE.Run(start: 9999, length: 1)])
        // Up to one row of overrun clamps; the run must start inside the frame.
        let rowOverrun = try MaskRLE.runs(from: "9950 150", width: 100, height: 100)
        #expect(rowOverrun == [MaskRLE.Run(start: 9950, length: 50)])
    }

    @Test func rejectsRunsFarPastPixelArea() {
        #expect(throws: MaskRLE.DecodeError.outOfBounds) {
            try MaskRLE.runs(from: "9999 200", width: 100, height: 100)
        }
        // Runs starting past the frame are invalid even with a small length.
        #expect(throws: MaskRLE.DecodeError.outOfBounds) {
            try MaskRLE.runs(from: "10000 1", width: 100, height: 100)
        }
        // Exactly reaching the last pixel is valid.
        #expect(throws: Never.self) {
            try MaskRLE.runs(from: "9998 2", width: 100, height: 100)
        }
    }

    @Test func payloadDecodesFromProviderJSON() throws {
        let json = #"{"rle": ["388 11", ""], "boxes": [[0.1, 0.2, 0.3, 0.4]], "metadata": [], "scores": null}"#
        let payload = try JSONDecoder().decode(MaskTrackPayload.self, from: Data(json.utf8))
        #expect(payload.rle.count == 2)
    }
}
