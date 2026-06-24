import CoreImage
import Foundation
import Testing
@testable import PalmierPro

/// Decides whether the HDR title overlay needs `.unpremultiplyingAlpha()`.
/// A 50%-alpha white over opaque black must render to ~50% grey; faded to opacity 0.5, ~25%.
@Suite("HDR premultiply diagnostic")
struct HDRPremultiplyDiag {

    /// premultipliedLast white at 50% alpha → bytes (128,128,128,128), like exportClipImages output.
    private func halfAlphaWhite(_ n: Int = 16) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        return ctx.makeImage()!
    }

    private func centerGrey(_ image: CIImage, size: Int = 16) -> Int {
        let ci = CIContext(options: [.workingColorSpace: HDRVideoExporter.titleWorkingSpace])
        var buf = [UInt8](repeating: 0, count: size * size * 4)
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        ci.render(image, toBitmap: &buf, rowBytes: size * 4,
                  bounds: CGRect(x: 0, y: 0, width: size, height: size),
                  format: .RGBA8, colorSpace: space)
        let i = (size / 2) * size * 4 + (size / 2) * 4
        return Int(buf[i + 1]) // green
    }

    /// Guards the HDR overlay compositing convention: `CIImage(cgImage:)` of a premultipliedLast
    /// bitmap composites and fades correctly *without* `.unpremultiplyingAlpha()`. Adding it (as a
    /// naive parallel to FrameRenderer's color-management-off path) double-divides and blows titles.
    @Test func overlayCompositesWithoutManualUnpremultiply() {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let raw = CIImage(cgImage: halfAlphaWhite())

        func faded(_ img: CIImage) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)])
        }
        let rawOver = centerGrey(raw.composited(over: black))
        let rawFade = centerGrey(faded(raw).composited(over: black))
        // 50%-alpha white over black → 50% grey; faded to opacity 0.5 → 25% grey.
        #expect(abs(rawOver - 128) <= 4, "overlay composite wrong (\(rawOver)); did someone add unpremultiply?")
        #expect(abs(rawFade - 64) <= 4, "overlay fade wrong (\(rawFade)); did someone add unpremultiply?")

        // The wrong path (what bugbot suggested) blows the picture out — assert it stays rejected.
        let unpremulOver = centerGrey(raw.unpremultiplyingAlpha().composited(over: black))
        #expect(unpremulOver > 200, "expected manual unpremultiply to over-brighten, got \(unpremulOver)")
    }
}
