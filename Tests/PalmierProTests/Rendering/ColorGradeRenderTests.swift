import Testing
import CoreImage
import Foundation
@testable import PalmierPro

@Suite("Color grade rendering")
struct ColorGradeRenderTests {

    @Test func gradesFixtureAndShiftsColor() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["GRADE_FIXTURE"], FileManager.default.fileExists(atPath: inPath) else {
            return

        }
        let outDir = env["GRADE_OUTDIR"] ?? NSTemporaryDirectory()
        let ctx = CIContext(options: nil)
        let working = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let src = CIImage(contentsOf: URL(fileURLWithPath: inPath)) else {
            Issue.record("could not load fixture at \(inPath)"); return
        }

        func avg(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
            let f = CIFilter(name: "CIAreaAverage")!
            f.setValue(image.clamped(to: src.extent), forKey: kCIInputImageKey)
            f.setValue(CIVector(cgRect: src.extent), forKey: "inputExtent")
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(f.outputImage!, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
            return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
        }

        let base = avg(src)
        for look in ColorGradeCatalog.all {
            let graded = look.process(src, colorSpace: working).cropped(to: src.extent)
            if let png = ctx.pngRepresentation(of: graded, format: .RGBA8, colorSpace: srgb) {
                try png.write(to: URL(fileURLWithPath: "\(outDir)/grade-\(look.id).png"))
            }
            let a = avg(graded)
            let delta = abs(a.r - base.r) + abs(a.g - base.g) + abs(a.b - base.b)
            #expect(delta > 0.003, "look \(look.id) barely changed the image")
        }

        // Warm look should read warmer (higher R−B) than the cool look on the same frame.
        let warm = avg(ColorGradeCatalog.look(id: "warm-cinematic")!.process(src, colorSpace: working))
        let cool = avg(ColorGradeCatalog.look(id: "moody-forest")!.process(src, colorSpace: working))
        #expect((warm.r - warm.b) > (cool.r - cool.b),
                "warm-cinematic should be warmer than moody-forest")

        // Full embedded-.cube path: parse → base64 embed → reconstruct → grade.
        if let cubePath = env["GRADE_CUBE"], FileManager.default.fileExists(atPath: cubePath) {
            let text = try String(contentsOf: URL(fileURLWithPath: cubePath), encoding: .utf8)
            let parsed = try CubeLUTParser.parse(text)
            let ref = LUTRef.cube(parsed, name: "test")
            let processor = try #require(ref.makeProcessor())
            let graded = processor.process(src, colorSpace: working).cropped(to: src.extent)
            if let png = ctx.pngRepresentation(of: graded, format: .RGBA8, colorSpace: srgb) {
                try png.write(to: URL(fileURLWithPath: "\(outDir)/grade-cube.png"))
            }
            let a = avg(graded)
            #expect((a.r - a.b) > (base.r - base.b), "warm test .cube should warm the image")
        }

        var primaries = PrimaryGrade()
        primaries.temperature = 40
        primaries.contrast = 30
        primaries.saturation = 25
        primaries.shadows = 35
        let pFilters = GradePipeline.filters(primaries: primaries, lut: nil)
        #expect(!pFilters.isEmpty)
        let pGraded = FilterChainProcessor(filters: pFilters).process(src, colorSpace: working).cropped(to: src.extent)
        if let png = ctx.pngRepresentation(of: pGraded, format: .RGBA8, colorSpace: srgb) {
            try png.write(to: URL(fileURLWithPath: "\(outDir)/grade-primaries.png"))
        }
        let pa = avg(pGraded)
        #expect((pa.r - pa.b) > (base.r - base.b), "warm primaries should warm the image")

        var curveGrade = PrimaryGrade()
        curveGrade.curve = GradeCurve(master: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.62), .init(x: 1, y: 1)])
        let cFilters = GradePipeline.filters(primaries: curveGrade, lut: nil)
        #expect(!cFilters.isEmpty)
        let cGraded = FilterChainProcessor(filters: cFilters).process(src, colorSpace: working).cropped(to: src.extent)
        if let png = ctx.pngRepresentation(of: cGraded, format: .RGBA8, colorSpace: srgb) {
            try png.write(to: URL(fileURLWithPath: "\(outDir)/grade-curve.png"))
        }
        let ca = avg(cGraded)
        #expect((ca.r + ca.g + ca.b) > (base.r + base.g + base.b), "midtone lift should brighten")
    }
}

private extension CIImage {
    func clamped(to rect: CGRect) -> CIImage { cropped(to: rect) }
}
