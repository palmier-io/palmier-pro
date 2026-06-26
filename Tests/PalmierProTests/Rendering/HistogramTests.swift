import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Scopes — histogram")
struct HistogramTests {

    private func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 32) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    private func argmax(_ a: [Float]) -> Int { a.indices.max { a[$0] < a[$1] }! }

    @Test func solidRedSpikesTopRedAndZeroGreenBlue() throws {
        let h = try #require(VideoEngine.histogram(from: solid(1, 0, 0)))
        #expect(argmax(h.r) >= 248, "red mass should sit in the top bins, got \(argmax(h.r))")
        #expect(argmax(h.g) == 0, "green is empty → bin 0")
        #expect(argmax(h.b) == 0, "blue is empty → bin 0")
        #expect(h.r.max() == 1, "histogram is normalized to a peak of 1")
    }

    /// Rec.709 luma of pure red is 0.2126 → bin ≈ 0.2126·255 ≈ 54.
    @Test func solidRedLumaUses709Weight() throws {
        let h = try #require(VideoEngine.histogram(from: solid(1, 0, 0)))
        #expect((44...64).contains(argmax(h.y)), "709 luma of red ~bin 54, got \(argmax(h.y))")
    }

    /// Pure green is the heaviest luma contributor (0.7152).
    @Test func solidGreenLumaBrighterThanRedAndBlue() throws {
        let green = argmax(try #require(VideoEngine.histogram(from: solid(0, 1, 0))).y)
        let red = argmax(try #require(VideoEngine.histogram(from: solid(1, 0, 0))).y)
        let blue = argmax(try #require(VideoEngine.histogram(from: solid(0, 0, 1))).y)
        #expect(green > red && red > blue, "luma order green>red>blue, got \(green),\(red),\(blue)")
    }

    @Test func midGraySpikesMiddleBin() throws {
        let h = try #require(VideoEngine.histogram(from: solid(0.5, 0.5, 0.5)))
        #expect((110...145).contains(argmax(h.r)), "mid-gray sits near bin 128, got \(argmax(h.r))")
    }
}
