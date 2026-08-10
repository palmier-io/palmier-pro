import CoreImage
import Foundation
import os
import Testing
@testable import PalmierPro

/// Serialized: the suite owns the rasterize hook, and counts are filtered by each
/// test's unique content so concurrent rasters from other suites don't interfere.
@Suite("TextFrameRenderer — raster cache", .serialized)
struct TextRasterCacheTests {
    private let size = CGSize(width: 640, height: 360)

    private func clip(content: String, anim: TextAnimation? = nil) -> Clip {
        var c = Clip(mediaRef: "", startFrame: 0, durationFrames: 90)
        c.mediaType = .text
        c.textContent = content
        var style = TextStyle()
        style.fontScale = 1.6
        c.textStyle = style
        c.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.25)
        c.textAnimation = anim
        return c
    }

    /// Rasterizations of `content` performed inside `body`.
    private func rasterCount(of content: String, _ body: () -> Void) -> Int {
        let counter = OSAllocatedUnfairLock(initialState: 0)
        TextFrameRenderer.onRasterize.withLock { hook in
            hook = { rasterized in
                if rasterized == content { counter.withLock { $0 += 1 } }
            }
        }
        defer { TextFrameRenderer.onRasterize.withLock { $0 = nil } }
        body()
        return counter.withLock { $0 }
    }

    private func uniqueContent(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    @Test func staticRasterCoversContentNotTheFullFrame() throws {
        let c = clip(content: uniqueContent("Tight"))
        let image = TextFrameRenderer.image(clip: c, frame: 0, renderSize: size)
        let extent = try #require(image?.extent)
        #expect(CGRect(origin: .zero, size: size).insetBy(dx: -64, dy: -64).contains(extent))
        #expect(extent.width * extent.height < size.width * size.height / 2,
                "raster should be caption-sized, got \(extent) in \(size)")
    }

    @Test func staticFramesAndWholePixelMovesReuseOneRaster() {
        var c = clip(content: uniqueContent("Static"))
        let count = rasterCount(of: c.textContent!) {
            _ = TextFrameRenderer.image(clip: c, frame: 0, renderSize: size)
            _ = TextFrameRenderer.image(clip: c, frame: 30, renderSize: size)
            c.transform.centerX += 0.0078125   // 5 px
            c.transform.centerY += 0.125       // 45 px
            _ = TextFrameRenderer.image(clip: c, frame: 0, renderSize: size)
        }
        #expect(count == 1, "expected one raster for static frames and whole-pixel moves, got \(count)")
    }

    @Test func entranceAnimationSharesOneBaseRaster() {
        let c = clip(content: uniqueContent("Entrance"), anim: TextAnimation(preset: .popIn))
        let count = rasterCount(of: c.textContent!) {
            for frame in 0..<8 {
                _ = TextFrameRenderer.image(clip: c, frame: frame, renderSize: size)
            }
        }
        #expect(count == 1, "entrance frames must reuse the static base, got \(count) rasters")
    }

    @Test func perWordSteadyFramesReuseRasterAndRampsDoNot() {
        // Five tokens over 90 frames → ramps start at 0, 18, 36, 54, 72 and settle after 6 frames.
        let c = clip(content: "ONE TWO THREE \(uniqueContent("FOUR"))",
                     anim: TextAnimation(preset: .wordReveal, perWordFrames: 6))
        let steady = rasterCount(of: c.textContent!) {
            _ = TextFrameRenderer.image(clip: c, frame: 8, renderSize: size)
            _ = TextFrameRenderer.image(clip: c, frame: 14, renderSize: size)
        }
        #expect(steady == 1, "steady per-word frames must reuse the raster, got \(steady)")

        let ramping = rasterCount(of: c.textContent!) {
            _ = TextFrameRenderer.image(clip: c, frame: 20, renderSize: size)
            _ = TextFrameRenderer.image(clip: c, frame: 21, renderSize: size)
        }
        #expect(ramping == 2, "distinct ramp states must re-raster, got \(ramping)")
    }

    @Test func typewriterHoldFramesReuseRaster() {
        let c = clip(content: uniqueContent("Aa Bb"), anim: TextAnimation(preset: .typewriter))
        let count = rasterCount(of: c.textContent!) {
            _ = TextFrameRenderer.image(clip: c, frame: 80, renderSize: size)  // held, same caret phase
            _ = TextFrameRenderer.image(clip: c, frame: 82, renderSize: size)
        }
        #expect(count == 1, "typewriter hold frames must reuse the raster, got \(count)")
    }

    @Test func translucentFillBorderPadsRasterBeyondTextBox() throws {
        // A border with a translucent fill strokes in a single pass (not drawsGlyphOutline);
        // the raster must still pad for it or edge strokes clip.
        var c = clip(content: uniqueContent("HHH"))
        var style = TextStyle(fontSize: 48)
        style.color.a = 0.5
        style.alignment = .left
        style.border = .init(enabled: true, color: .init(r: 1, g: 0, b: 0, a: 1), width: 40)
        c.textStyle = style
        c.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.25)

        let image = try #require(TextFrameRenderer.image(clip: c, frame: 0, renderSize: size))
        let boxMinX = 0.25 * size.width
        #expect(image.extent.minX <= boxMinX - 10,
                "raster must pad for single-pass border strokes, got \(image.extent)")

        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let bg = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        let w = Int(size.width), h = Int(size.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(image.unpremultiplyingAlpha().composited(over: bg), toBitmap: &px, rowBytes: w * 4,
                   bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        var strokePixelsOutsideBox = 0
        for y in 0..<h {
            for x in (Int(boxMinX) - 7)..<(Int(boxMinX) - 2) where px[(y * w + x) * 4] > 100 {
                strokePixelsOutsideBox += 1
            }
        }
        #expect(strokePixelsOutsideBox > 0, "border stroke left of the text box must survive the raster crop")
    }

    @Test func reusedRasterCompositesAtTheClipPosition() throws {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var c = clip(content: uniqueContent("MOVE"))
        c.transform = Transform(centerX: 0.25, centerY: 0.5, width: 0.5, height: 0.25)

        func brightestColumnStart(_ clip: Clip) -> Int? {
            guard let text = TextFrameRenderer.image(clip: clip, frame: 0, renderSize: size) else { return nil }
            let bg = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
            let w = Int(size.width), h = Int(size.height)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            ctx.render(text.composited(over: bg), toBitmap: &px, rowBytes: w * 4,
                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
            for x in 0..<w {
                for y in 0..<h where px[(y * w + x) * 4] > 128 { return x }
            }
            return nil
        }

        var count = 0
        var before: Int?
        var after: Int?
        count = rasterCount(of: c.textContent!) {
            before = brightestColumnStart(c)
            c.transform.centerX += 0.25   // 160 px, whole-pixel move → raster reused
            after = brightestColumnStart(c)
        }
        let beforeX = try #require(before)
        let afterX = try #require(after)
        #expect(count == 1, "whole-pixel move must reuse the raster, got \(count)")
        #expect(afterX == beforeX + 160,
                "reused raster must composite at the moved position: \(beforeX) → \(afterX)")
    }
}
