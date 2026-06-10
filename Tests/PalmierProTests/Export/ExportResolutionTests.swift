import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("ExportResolution.renderSize")
struct ExportResolutionTests {

    // MARK: - shortSidePixels mapping

    @Test func shortSidePixelsForEachPreset() {
        #expect(ExportResolution.r720p.shortSidePixels == 720)
        #expect(ExportResolution.r1080p.shortSidePixels == 1080)
        #expect(ExportResolution.r4k.shortSidePixels == 2160)
    }

    // MARK: - Landscape canvases

    @Test func landscapeCanvas1080pPreservesAspect() {
        // 1920×1080 canvas at 1080p: short side already 1080, scale=1, no change.
        let size = ExportResolution.r1080p.renderSize(for: CGSize(width: 1920, height: 1080))
        #expect(size == CGSize(width: 1920, height: 1080))
    }

    @Test func landscape4kScalesShortSideTo2160() {
        // 1920×1080 canvas at 4K: short side 1080 → 2160, scale=2.
        let size = ExportResolution.r4k.renderSize(for: CGSize(width: 1920, height: 1080))
        #expect(size == CGSize(width: 3840, height: 2160))
    }

    @Test func landscape720pDownscalesShortSideTo720() {
        // 1920×1080 → 1280×720 at 720p.
        let size = ExportResolution.r720p.renderSize(for: CGSize(width: 1920, height: 1080))
        #expect(size == CGSize(width: 1280, height: 720))
    }

    // MARK: - Portrait canvases (short side = width)

    @Test func portraitCanvasUsesWidthAsShortSide() {
        // 1080×1920 at 1080p: short side already 1080 → no change.
        let size = ExportResolution.r1080p.renderSize(for: CGSize(width: 1080, height: 1920))
        #expect(size == CGSize(width: 1080, height: 1920))
    }

    @Test func portrait4kScalesWidthTo2160() {
        // 1080×1920 → 2160×3840 at 4K.
        let size = ExportResolution.r4k.renderSize(for: CGSize(width: 1080, height: 1920))
        #expect(size == CGSize(width: 2160, height: 3840))
    }

    // MARK: - Square canvases

    @Test func squareCanvasScalesBothDimensions() {
        // 1080×1080 → 720×720 at 720p.
        let size = ExportResolution.r720p.renderSize(for: CGSize(width: 1080, height: 1080))
        #expect(size == CGSize(width: 720, height: 720))
    }

    // MARK: - Even-dimension constraint

    @Test func resultDimensionsAreAlwaysEven() {
        // h264/h265 require even dimensions; the function rounds and clamps to multiples of 2.
        // A 1081×1081 canvas at 720p would naively produce 720.667 → ensure both end up even.
        let size = ExportResolution.r720p.renderSize(for: CGSize(width: 1081, height: 1081))
        #expect(Int(size.width) % 2 == 0, "width \(size.width) is not even")
        #expect(Int(size.height) % 2 == 0, "height \(size.height) is not even")
    }

    @Test func tightlyOddCanvasProducesEvenScaledOutput() {
        // 1921×1080 at 720p: scale = 720/1080 ≈ 0.667, w ≈ 1281.33 → floored to 1280, h = 720.
        let size = ExportResolution.r720p.renderSize(for: CGSize(width: 1921, height: 1080))
        #expect(Int(size.width) % 2 == 0)
        #expect(Int(size.height) % 2 == 0)
    }

    // MARK: - Degenerate inputs

    @Test func zeroShortSideReturnsCanvasUntouched() {
        // shortSide=0 triggers the guard; function returns the input unchanged.
        let canvas = CGSize(width: 1920, height: 0)
        let size = ExportResolution.r1080p.renderSize(for: canvas)
        #expect(size == canvas)
    }

    @Test func tinyCanvasClampsToMinimumOfTwo() {
        // 1×1 canvas at 720p: scale = 720, w = 720, h = 720 — but check the (max 2) clamp
        // still kicks in for canvases where rounding would produce zero. The contract is
        // "result is never below 2 on either axis."
        let size = ExportResolution.r720p.renderSize(for: CGSize(width: 1, height: 1))
        #expect(size.width >= 2)
        #expect(size.height >= 2)
    }
}
