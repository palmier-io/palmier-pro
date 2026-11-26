import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Background remover")
struct BackgroundRemoverTests {
    private static func solid(_ size: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    /// Plain mask samples. The compositing maths is proved against these rather than against a
    /// CVPixelBuffer, so the tests do not depend on CoreVideo allocation succeeding.
    private static func mask(_ values: [UInt8], width: Int, height: Int) -> BackgroundRemover.MaskSamples {
        BackgroundRemover.MaskSamples(values: values, width: width, height: height)
    }

    @Test("A mask of all ones leaves the picture fully opaque")
    func fullMaskIsOpaque() throws {
        let image = Self.solid(32, r: 0.2, g: 0.4, b: 0.8)
        let mask = Self.mask([UInt8](repeating: 255, count: 32 * 32), width: 32, height: 32)
        let out = try #require(BackgroundRemover.compose(image: image, samples: mask, featherRadius: 0))
        #expect(out.width == 32 && out.height == 32)
        #expect(Self.alphaCoverage(of: out) == 1.0)
    }

    @Test("A mask of all zeroes clears every pixel, which is the point of the tool")
    func emptyMaskClears() throws {
        let image = Self.solid(16, r: 0.9, g: 0.1, b: 0.1)
        let mask = Self.mask([UInt8](repeating: 0, count: 16 * 16), width: 16, height: 16)
        let out = try #require(BackgroundRemover.compose(image: image, samples: mask, featherRadius: 0))
        #expect(Self.alphaCoverage(of: out) == 0.0)
    }

    @Test("A half mask keeps half the picture and drops the rest")
    func partialMask() throws {
        let image = Self.solid(16, r: 0.5, g: 0.5, b: 0.5)
        // Top half opaque, bottom half clear.
        var values = [UInt8](repeating: 0, count: 16 * 16)
        for y in 0 ..< 8 {
            for x in 0 ..< 16 { values[y * 16 + x] = 255 }
        }
        let out = try #require(
            BackgroundRemover.compose(
                image: image, samples: Self.mask(values, width: 16, height: 16), featherRadius: 0
            )
        )
        let coverage = Self.alphaCoverage(of: out)
        #expect(abs(coverage - 0.5) < 0.02)
    }

    @Test("A mask at a different size is resampled rather than misread")
    func resamplesMismatchedMask() throws {
        let image = Self.solid(64, r: 0.3, g: 0.3, b: 0.3)
        // A 16x16 mask against a 64x64 source must still fill it.
        let mask = Self.mask([UInt8](repeating: 255, count: 16 * 16), width: 16, height: 16)
        let out = try #require(BackgroundRemover.compose(image: image, samples: mask, featherRadius: 0))
        #expect(Self.alphaCoverage(of: out) == 1.0)
    }

    @Test("Feathering softens a hard edge instead of leaving a sticker cutout")
    func featherSoftensEdge() throws {
        let image = Self.solid(64, r: 0.5, g: 0.5, b: 0.5)
        var values = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0 ..< 32 {
            for x in 0 ..< 64 { values[y * 64 + x] = 255 }
        }
        let hard = try #require(
            BackgroundRemover.compose(
                image: image, samples: Self.mask(values, width: 64, height: 64), featherRadius: 0
            )
        )
        let soft = try #require(
            BackgroundRemover.compose(
                image: image, samples: Self.mask(values, width: 64, height: 64), featherRadius: 6
            )
        )
        #expect(Self.partialAlphaFraction(of: soft) > Self.partialAlphaFraction(of: hard))
        #expect(Self.partialAlphaFraction(of: hard) == 0, "no feather means no partial alpha")
    }

    @Test("Feather of zero changes nothing")
    func zeroFeatherIsIdentity() {
        let input = [UInt8](repeating: 255, count: 64)
        #expect(BackgroundRemover.blur(input, width: 8, height: 8, radius: 0) == input)
    }

    @Test("Blur preserves mean coverage, so feathering does not shrink the subject")
    func blurPreservesCoverage() {
        let width = 32
        let height = 32
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< 16 {
            for x in 0 ..< width { values[y * width + x] = 255 }
        }
        let blurred = BackgroundRemover.blur(values, width: width, height: height, radius: 3)
        let before = values.reduce(0) { $0 + Int($1) }
        let after = blurred.reduce(0) { $0 + Int($1) }
        // Box blur is mean-preserving except at the very edge, which the values below tolerate.
        #expect(abs(Double(before - after)) < Double(before) * 0.1)
    }

    @Test("Subject coverage is measured from the samples, not guessed")
    func coverageFromSamples() {
        #expect(BackgroundRemover.coverage(of: Self.mask([UInt8](repeating: 255, count: 100), width: 10, height: 10)) == 1.0)
        #expect(BackgroundRemover.coverage(of: Self.mask([UInt8](repeating: 0, count: 100), width: 10, height: 10)) == 0.0)
        let quarter = Self.mask(
            [UInt8](repeating: 255, count: 25) + [UInt8](repeating: 0, count: 75),
            width: 10, height: 10
        )
        #expect(abs(BackgroundRemover.coverage(of: quarter) - 0.25) < 0.001)
    }

    @Test("Flattening onto a colour makes the cutout opaque")
    func flattenMakesOpaque() throws {
        let image = Self.solid(16, r: 1, g: 0, b: 0)
        let mask = Self.mask([UInt8](repeating: 255, count: 32) + [UInt8](repeating: 0, count: 224),
                                   width: 16, height: 16)
        let cutout = try #require(
            BackgroundRemover.compose(image: image, samples: mask, featherRadius: 0)
        )
        #expect(Self.alphaCoverage(of: cutout) < 1.0, "the cutout has transparency")
        let flat = try #require(
            EditorViewModel.flatten(cutout, onto: TextStyle.RGBA(r: 1, g: 1, b: 1, a: 1))
        )
        #expect(Self.alphaCoverage(of: flat) == 1.0)
    }

    @Test("A mode explains itself, and both modes are offered")
    func modesAreDescribed() {
        #expect(BackgroundRemover.Mode.allCases.count == 2)
        for mode in BackgroundRemover.Mode.allCases {
            #expect(!mode.guidance.isEmpty)
        }
    }

    @Test("The no-subject refusal tells the user what to do instead")
    func refusalIsActionable() {
        let text = BackgroundRemover.RemoveError.noSubjectFound.description
        #expect(text.contains("chroma key"))
    }

    // MARK: - Helpers

    private static func alphaCoverage(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0
        var partial = 0
        for index in stride(from: 3, to: data.count, by: 4) {
            total += Int(data[index])
            if data[index] > 0 && data[index] < 255 { partial += 1 }
        }
        _ = partial
        return Double(total) / Double(width * height * 255)
    }

    private static func partialAlphaFraction(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var partial = 0
        for index in stride(from: 3, to: data.count, by: 4) where data[index] > 0 && data[index] < 255 {
            partial += 1
        }
        return Double(partial) / Double(width * height)
    }
}