import AppKit
import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("InspectFrameOverlay")
struct InspectFrameOverlayTests {
    @Test func preservesSize() {
        let overlaid = InspectFrameOverlay.apply(solid(200, 100), caption: "f12")
        #expect(overlaid.width == 200)
        #expect(overlaid.height == 100)
    }

    @Test func paintsGridAtHalfAndLeavesInterior() {
        let pixels = NSBitmapImageRep(cgImage: InspectFrameOverlay.apply(solid(200, 200)))
        #expect(isLit(pixels, x: 100, y: 100), "0.5,0.5 intersection should be a grid line")
        #expect(isLit(pixels, x: 100, y: 60), "vertical 0.5 line")
        #expect(isLit(pixels, x: 60, y: 100), "horizontal 0.5 line")
        #expect(isGrid(pixels, x: 10, y: 80), "vertical 0.05 line")
        #expect(isGrid(pixels, x: 80, y: 10), "horizontal 0.05 line")
        #expect(!isGrid(pixels, x: 35, y: 75), "off-grid interior should stay the fill")
    }

    @Test func yZeroIsTheTopEdge() {
        let pixels = NSBitmapImageRep(cgImage: InspectFrameOverlay.apply(solid(200, 200)))
        #expect(isLit(pixels, x: 100, y: 0), "y=0 is the top of the image")
        #expect(isLit(pixels, x: 0, y: 100), "x=0 is the left of the image")
    }

    @Test func overlayKeepsClearPixelsTransparent() throws {
        let source = checker(200, 200)
        let overlaid = InspectFrameOverlay.apply(source)
        let pixels = NSBitmapImageRep(cgImage: overlaid)
        let color = try #require(pixels.colorAt(x: 35, y: 75))
        #expect(color.alphaComponent < 0.05)
        #expect(InspectFrameOverlay.hasAlpha(source))
    }

    @Test func encodePreservesAlphaAsPNGAndOpaqueAsJPEG() throws {
        let transparent = try #require(InspectFrameOverlay.encode(checker(200, 200)))
        #expect(transparent.mime == "image/png")
        #expect(transparent.data.count <= ImageEncoder.maxBytes)
        let png = try #require(NSBitmapImageRep(data: transparent.data))
        let clear = try #require(png.colorAt(x: 35, y: 75))
        #expect(clear.alphaComponent < 0.05)

        let opaque = try #require(InspectFrameOverlay.encode(solid(200, 200)))
        #expect(opaque.mime == "image/jpeg")
        #expect(opaque.data.count <= ImageEncoder.maxBytes)
    }

    @Test func encodeKeepsLargeAlphaStillsWithinInspectBudget() throws {
        let encoded = try #require(InspectFrameOverlay.encode(noisyRGBA(ImageEncoder.maxLongestEdge, ImageEncoder.maxLongestEdge)))
        #expect(encoded.data.count <= ImageEncoder.maxBytes)
    }

    @Test func captionMarksTopLeft() {
        let plain = NSBitmapImageRep(cgImage: InspectFrameOverlay.apply(solid(200, 200)))
        let labeled = NSBitmapImageRep(cgImage: InspectFrameOverlay.apply(solid(200, 200), caption: "f12"))
        var differs = false
        for y in 0..<16 {
            for x in 0..<24 {
                if let a = plain.colorAt(x: x, y: y), let b = labeled.colorAt(x: x, y: y),
                   abs(a.redComponent - b.redComponent) > 0.05
                    || abs(a.greenComponent - b.greenComponent) > 0.05
                    || abs(a.blueComponent - b.blueComponent) > 0.05 {
                    differs = true
                    break
                }
            }
        }
        #expect(differs)
    }

    private func solid(_ width: Int, _ height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func checker(_ width: Int, _ height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        return ctx.makeImage()!
    }

    private func noisyRGBA(_ width: Int, _ height: Int) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        return pixels.withUnsafeMutableBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: buf.count, by: 4) {
                buf[i] = UInt8(truncatingIfNeeded: i &* 131)
                buf[i + 1] = UInt8(truncatingIfNeeded: i &* 67)
                buf[i + 2] = UInt8(truncatingIfNeeded: i / 17)
                buf[i + 3] = 255
            }
            let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func isLit(_ pixels: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        hasLuma(pixels, x: x, y: y, above: 1.6)
    }

    private func isGrid(_ pixels: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        hasLuma(pixels, x: x, y: y, above: 0.8)
    }

    private func hasLuma(_ pixels: NSBitmapImageRep, x: Int, y: Int, above: CGFloat) -> Bool {
        for dy in -2...2 {
            for dx in -2...2 {
                guard let color = pixels.colorAt(
                    x: min(max(0, x + dx), pixels.pixelsWide - 1),
                    y: min(max(0, y + dy), pixels.pixelsHigh - 1)
                ) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent > above {
                    return true
                }
            }
        }
        return false
    }
}
