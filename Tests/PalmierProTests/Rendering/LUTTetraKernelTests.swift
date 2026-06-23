import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("LUTTetraKernel")
struct LUTTetraKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private func sample(_ image: CIImage) -> (Double, Double, Double) {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    private func d(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
    }

    /// Build an n³ cube whose value at node (r,g,b) is `f(r/(n-1), g/(n-1), b/(n-1))`.
    private func cube(_ n: Int, _ f: (Double, Double, Double) -> (Double, Double, Double)) -> LUTLoader.CubeLUT {
        var d = [Float]()
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let v = f(Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                    d.append(Float(v.0)); d.append(Float(v.1)); d.append(Float(v.2)); d.append(1)
                }
            }
        }
        return LUTLoader.CubeLUT(dimension: n, data: d.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    @Test func identityLUTIsPassthrough() {
        let id = cube(4) { ($0, $1, $2) }
        for c in [(0.6, 0.3, 0.8), (0.12, 0.5, 0.9), (0.33, 0.33, 0.33)] {
            #expect(d(sample(LUTTetraKernel.apply(solid(c.0, c.1, c.2), cube: id, key: "id4", intensity: 1)), c) < 1e-3,
                    "identity passthrough \(c)")
        }
    }

    @Test func invertLUTInverts() {
        let inv = cube(2) { (1 - $0, 1 - $1, 1 - $2) }
        #expect(d(sample(LUTTetraKernel.apply(solid(0.6, 0.3, 0.8), cube: inv, key: "inv2", intensity: 1)), (0.4, 0.7, 0.2)) < 1e-3)
    }

    @Test func intensityBlends() {
        let inv = cube(2) { (1 - $0, 1 - $1, 1 - $2) }
        let img = solid(0.8, 0.2, 0.2)
        #expect(d(sample(LUTTetraKernel.apply(img, cube: inv, key: "inv2", intensity: 0)), (0.8, 0.2, 0.2)) < 1e-3, "0 = original")
        let half = sample(LUTTetraKernel.apply(img, cube: inv, key: "inv2", intensity: 0.5))
        #expect(d(half, (0.5, 0.5, 0.5)) < 1e-2, "0.5 = halfway to inverted, got \(half)")
    }
}
