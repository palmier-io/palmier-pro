import Testing
@testable import PalmierPro

@Suite("Cube LUT parsing")
struct CubeLUTParserTests {

    // 2×2×2 identity cube; red varies fastest.
    static let identity2 = """
    # sample identity LUT
    TITLE "identity"
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

    @Test func parsesDimensionAndCount() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        #expect(lut.dimension == 2)
        #expect(lut.rgbaTable.count == 2 * 2 * 2 * 4)   // 8 entries × RGBA
    }

    @Test func forcesAlphaToOne() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        for i in stride(from: 3, to: lut.rgbaTable.count, by: 4) {
            #expect(lut.rgbaTable[i] == 1)
        }
    }

    @Test func preservesFileOrderRedFastest() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        // Second entry is (1,0,0) — red advanced first.
        #expect(lut.rgbaTable[4] == 1)
        #expect(lut.rgbaTable[5] == 0)
        #expect(lut.rgbaTable[6] == 0)
    }

    @Test func defaultDomainIsZeroToOne() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        #expect(!lut.hasNonDefaultDomain)
    }

    @Test func ignoresCommentsAndBlankLines() throws {
        let text = "\n# a\n\nLUT_3D_SIZE 2\n# b\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n\n"
        #expect(throws: Never.self) { try CubeLUTParser.parse(text) }
    }

    @Test func missingSizeThrows() {
        #expect(throws: CubeLUTParser.ParseError.missingSize) {
            try CubeLUTParser.parse("0 0 0\n1 1 1")
        }
    }

    @Test func oneDimensionalIsRejected() {
        #expect(throws: CubeLUTParser.ParseError.unsupported1D) {
            try CubeLUTParser.parse("LUT_1D_SIZE 4\n0 0 0\n1 1 1")
        }
    }

    @Test func wrongRowCountThrows() {
        #expect(throws: CubeLUTParser.ParseError.wrongRowCount(expected: 8, got: 3)) {
            try CubeLUTParser.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0")
        }
    }

    @Test func malformedRowThrows() {
        #expect(throws: (any Error).self) {
            try CubeLUTParser.parse("LUT_3D_SIZE 2\n0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        }
    }

    @Test func base64RoundTripPreservesTable() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        let restored = CubeLUT(base64: lut.base64, dimension: lut.dimension)
        #expect(restored != nil)
        #expect(restored?.dimension == lut.dimension)
        #expect(restored?.rgbaTable == lut.rgbaTable)
    }

    @Test func base64RejectsWrongDimension() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        // Claiming dimension 3 against dimension-2 data must fail, not crash.
        #expect(CubeLUT(base64: lut.base64, dimension: 3) == nil)
    }

    @Test func lutRefCubeSummaryOmitsBlob() throws {
        let lut = try CubeLUTParser.parse(Self.identity2)
        let ref = LUTRef.cube(lut, name: "myfilm", intensity: 0.8)
        let summary = ref.summary
        #expect(summary["cube"] as? String == "myfilm")
        #expect(summary["dimension"] as? Int == 2)
        #expect(summary["kind"] as? String == "cube")
        #expect(summary["cubeBase64"] == nil)   // blob never in summary
        #expect(ref.makeProcessor() != nil)
    }

    @Test func parsesNonDefaultDomain() throws {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 4 4 4\n"
            + (0..<8).map { _ in "0.5 0.5 0.5" }.joined(separator: "\n")
        let lut = try CubeLUTParser.parse(text)
        #expect(lut.hasNonDefaultDomain)
        #expect(lut.domainMax == .init(4, 4, 4))
    }
}
