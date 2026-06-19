import Testing
import Foundation
@testable import PalmierPro

@Suite("CubeLUT parsing")
struct CubeLUTTests {

    static let identity2 = """
    # identity 2x2x2
    TITLE "id"
    LUT_3D_SIZE 2
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """

    @Test func parsesSizeAndLength() throws {
        let lut = try CubeLUT.parse(Self.identity2)
        #expect(lut.size == 2)
        #expect(lut.rgbaData.count == 2 * 2 * 2 * 4)
    }

    @Test func firstAndLastEntriesIncludeAlpha() throws {
        let lut = try CubeLUT.parse(Self.identity2)
        #expect(Array(lut.rgbaData.prefix(4)) == [0, 0, 0, 1])
        #expect(Array(lut.rgbaData.suffix(4)) == [1, 1, 1, 1])
    }

    @Test func redVariesFastest() throws {
        let lut = try CubeLUT.parse(Self.identity2)
        // Second entry is r=1,g=0,b=0.
        #expect(Array(lut.rgbaData[4..<8]) == [1, 0, 0, 1])
    }

    @Test func clampsOutOfRangeValues() throws {
        let text = "LUT_3D_SIZE 2\n-0.5 0 0\n2 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1"
        let lut = try CubeLUT.parse(text)
        #expect(lut.rgbaData[0] == 0)  // -0.5 clamped
        #expect(lut.rgbaData[4] == 1)  // 2 clamped
    }

    @Test func missingSizeThrows() {
        #expect(throws: CubeLUT.ParseError.self) {
            try CubeLUT.parse("0 0 0\n1 1 1")
        }
    }

    @Test func wrongRowCountThrows() {
        #expect(throws: CubeLUT.ParseError.self) {
            try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1")
        }
    }

    @Test func parses1DAsExpandedCube() throws {
        // 1D ramp of size 2: black→white per channel.
        let lut = try CubeLUT.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1")
        #expect(lut.size == 2)
        #expect(lut.rgbaData.count == 2 * 2 * 2 * 4)
        // Corner (r=1,g=1,b=1) maps to white.
        #expect(Array(lut.rgbaData.suffix(4)) == [1, 1, 1, 1])
    }
}
