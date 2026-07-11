import Foundation
import Testing
@testable import PalmierPro

@Suite("LUTLoader")
struct LUTLoaderTests {

    private func cubeText(size n: Int) -> String {
        var lines = ["LUT_3D_SIZE \(n)"]
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let v = Double(r) / Double(n - 1)
                    let vg = Double(g) / Double(n - 1)
                    let vb = Double(b) / Double(n - 1)
                    lines.append("\(v) \(vg) \(vb)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func parses33PointCube() {
        let lut = LUTLoader.parse(cubeText(size: 33))
        #expect(lut?.dimension == 33)
    }

    @Test func parses65PointCube() {
        let lut = LUTLoader.parse(cubeText(size: 65))
        #expect(lut?.dimension == 65)
        #expect(lut?.data.count == 65 * 65 * 65 * 4 * MemoryLayout<Float>.size)
    }

    @Test func rejects1DLUT() {
        #expect(LUTLoader.parse("LUT_1D_SIZE 16\n0 0 0") == nil)
    }
}
