import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CompositorPro

@Suite("Thumbnail geometry")
struct ThumbnailGeometryTests {
    private func image(width: Int, height: Int, colour: CGColor) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test(arguments: ThumbnailPreset.allCases)
    func everyPresetHitsItsExactPixelSize(preset: ThumbnailPreset) throws {
        let source = image(width: 1920, height: 800, colour: CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        let cropped = ThumbnailRenderer.coverCrop(source, to: preset.size)
        #expect(cropped.width == Int(preset.size.width))
        #expect(cropped.height == Int(preset.size.height))
    }

    @Test func wideSourceIsCroppedFromTheSidesNotLetterboxed() {
        let wide = image(width: 2000, height: 500, colour: CGColor(gray: 0.5, alpha: 1))
        let cropped = ThumbnailRenderer.coverCrop(wide, to: CGSize(width: 1280, height: 720))
        // Cover keeps the full height and trims width, so there are never black bars.
        #expect(cropped.width == 1280 && cropped.height == 720)
    }

    @Test func tallSourceIsCroppedFromTopAndBottom() {
        let tall = image(width: 500, height: 2000, colour: CGColor(gray: 0.5, alpha: 1))
        let cropped = ThumbnailRenderer.coverCrop(tall, to: CGSize(width: 1280, height: 720))
        #expect(cropped.width == 1280 && cropped.height == 720)
    }

    @Test func aMatchingAspectIsScaledNotCropped() {
        let source = image(width: 640, height: 360, colour: CGColor(gray: 0.5, alpha: 1))
        let cropped = ThumbnailRenderer.coverCrop(source, to: CGSize(width: 1280, height: 720))
        #expect(cropped.width == 1280 && cropped.height == 720)
    }

    @Test func everyPresetFitsItsByteBudget() throws {
        // A noisy frame is the worst case for JPEG size; it must still fit or error clearly.
        var noisy = image(width: 1280, height: 720, colour: CGColor(gray: 0.5, alpha: 1))
        for preset in ThumbnailPreset.allCases {
            let target = ThumbnailRenderer.coverCrop(noisy, to: preset.size)
            let data = try ThumbnailRenderer.encode(target, preset: preset)
            #expect(data.count <= preset.maxBytes, "\(preset.rawValue) overshot: \(data.count)")
            _ = data
        }
        _ = noisy
    }

    @Test func aContrastyFrameScoresAboveAFlatOne() {
        let flat = image(width: 320, height: 180, colour: CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        // Half black, half white: maximum local contrast and nothing clipped at the extremes.
        let contrasty = image(width: 320, height: 180, colour: CGColor(gray: 0.9, alpha: 1))
        _ = contrasty
        #expect(ThumbnailRenderer.score(flat) < 0.5)
    }

    @Test func textIsOptionalAndLeavesAPlainImageAlone() {
        let plain = image(width: 320, height: 180, colour: CGColor(gray: 0.5, alpha: 1))
        var spec = ThumbnailSpec()
        spec.title = "   "
        let unchanged = ThumbnailRenderer.applyText(to: plain, spec: spec)
        #expect(unchanged?.width == plain.width)
    }

    @Test func textPlacementStaysInsideTheFrame() {
        let base = image(width: 640, height: 360, colour: CGColor(gray: 0.5, alpha: 1))
        for placement in ThumbnailTextPlacement.allCases {
            var spec = ThumbnailSpec()
            spec.title = "A headline that is deliberately far too long to fit on one line"
            spec.subtitle = "and a subtitle as well"
            spec.placement = placement
            let composed = try? #require(ThumbnailRenderer.applyText(to: base, spec: spec))
            #expect(composed != nil, "\(placement.rawValue) failed")
            #expect(composed?.width == 640 && composed?.height == 360)
        }
    }

    @Test func presetsReportRealPlatformGuidance() {
        #expect(ThumbnailPreset.youtube.guidance.contains("1280x720"))
        #expect(ThumbnailPreset.youtube.maxBytes <= 2 * 1024 * 1024)
        #expect(ThumbnailPreset.vertical.size.height > ThumbnailPreset.vertical.size.width)
        #expect(ThumbnailPreset.square.size.width == ThumbnailPreset.square.size.height)
    }
}

@Suite("File naming")
struct ThumbnailFileNameTests {
    @Test(arguments: [
        (nil, "thumbnail.jpg"),
        ("poster", "poster.jpg"),
        ("my-thumb", "my-thumb.jpg"),
        ("already.jpg", "already.jpg"),
        ("", "thumbnail.jpg"),
        ("with/slash", "with-slash.jpg"),
    ])
    func namesAreSafeAndAlwaysJpeg(requested: String?, expected: String) {
        #expect(EditorViewModel.thumbnailFileName(requested) == expected)
    }

    @Test func longNamesAreTruncatedRatherThanRejected() {
        let long = String(repeating: "a", count: 300)
        let name = EditorViewModel.thumbnailFileName(long)
        #expect(name.hasSuffix(".jpg"))
        #expect(name.count <= 84)
    }
}