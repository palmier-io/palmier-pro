import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("TextFrameRenderer")
struct TextFrameRendererTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func textClip(content: String, style: TextStyle, transform: Transform) -> Clip {
        var c = Clip(mediaRef: "", startFrame: 0, durationFrames: 60)
        c.mediaType = .text
        c.sourceClipType = .text
        c.textContent = content
        c.textStyle = style
        c.transform = transform
        return c
    }

    /// Mirror FrameRenderer's text path: unpremultiply, composite over gray, render unmanaged.
    private func composited(_ text: CIImage, over gray: Double, size: CGSize) -> [UInt8] {
        let bg = CIImage(color: CIColor(red: gray, green: gray, blue: gray))
            .cropped(to: CGRect(origin: .zero, size: size))
        let out = text.unpremultiplyingAlpha().composited(over: bg)
        let w = Int(size.width), h = Int(size.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(out, toBitmap: &px, rowBytes: w * 4,
                   bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        return px
    }

    private func rawPixels(_ text: CIImage, size: CGSize) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(text, toBitmap: &px, rowBytes: w * 4,
                   bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        return px
    }

    @Test func whiteTextIsBrightAndColorMatches() {
        let size = CGSize(width: 640, height: 360)
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.shadow.enabled = false
        let clip = textClip(content: "Ag", style: style,
                            transform: Transform(topLeft: (0.2, 0.4), width: 0.6, height: 0.2))
        let img = TextFrameRenderer.image(clip: clip, frame: 0, renderSize: size)
        #expect(img != nil)
        let px = composited(img!, over: 0.5, size: size)

        // Brightest pixel should be near-white (text), proving color + alpha survive.
        var maxLuma: Int = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            maxLuma = max(maxLuma, Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]))
        }
        #expect(maxLuma > 720, "expected near-white text pixels, got max sum \(maxLuma)/765")
    }

    @Test func textRendersTopWhenPlacedTop() {
        let size = CGSize(width: 640, height: 360)
        let w = Int(size.width), h = Int(size.height)
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.fontScale = 1.5
        style.shadow.enabled = false
        let clip = textClip(content: "TOP", style: style,
                            transform: Transform(topLeft: (0.0, 0.0), width: 1.0, height: 0.25))
        let img = TextFrameRenderer.image(clip: clip, frame: 0, renderSize: size)!
        let px = composited(img, over: 0.5, size: size)

        // Output row 0 = top: text in the top box should land in the top half.
        func brightCount(rows: Range<Int>) -> Int {
            var n = 0
            for y in rows {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 600 { n += 1 }
                }
            }
            return n
        }
        #expect(brightCount(rows: 0..<(h / 2)) > brightCount(rows: (h / 2)..<h) * 4,
                "text placed at top should render at top")
    }

    @Test func borderOutlinesGlyphsWithoutBoxStroke() {
        let size = CGSize(width: 640, height: 360)
        let w = Int(size.width)
        var style = TextStyle()
        style.fontSize = 200
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.border = .init(enabled: true, color: .init(r: 1, g: 0, b: 0, a: 1))
        style.shadow.enabled = false
        let transform = Transform(topLeft: (0.2, 0.25), width: 0.6, height: 0.35)
        let clip = textClip(content: "A", style: style, transform: transform)
        let img = TextFrameRenderer.image(clip: clip, frame: 0, renderSize: size)!
        let px = rawPixels(img, size: size)

        func isRed(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return px[i] > 96 && px[i + 1] < 80 && px[i + 2] < 80 && px[i + 3] > 32
        }

        let left = Int((transform.topLeft.x * size.width).rounded())
        let right = Int(((transform.topLeft.x + transform.width) * size.width).rounded())
        let top = Int((transform.topLeft.y * size.height).rounded())
        let bottom = Int(((transform.topLeft.y + transform.height) * size.height).rounded())

        var totalRed = 0
        for y in 0..<Int(size.height) {
            for x in 0..<w where isRed(x, y) {
                totalRed += 1
            }
        }

        var edgeRed = 0
        for x in left...right {
            if isRed(x, top) { edgeRed += 1 }
            if isRed(x, bottom) { edgeRed += 1 }
        }
        for y in top...bottom {
            if isRed(left, y) { edgeRed += 1 }
            if isRed(right, y) { edgeRed += 1 }
        }

        #expect(totalRed > 10, "expected visible red glyph outline")
        #expect(edgeRed < 50, "border should not render a rectangular clip box")
    }

    @Test func backgroundRendersRoundedFillAndIndependentOutline() {
        let size = CGSize(width: 640, height: 360)
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 0)
        style.shadow.enabled = false
        style.background = .init(
            enabled: true,
            color: .init(r: 1, g: 0, b: 0, a: 1),
            paddingX: 24,
            paddingY: 12,
            cornerRadius: 48,
            offsetX: 8,
            offsetY: -6,
            outlineColor: .init(r: 0, g: 0, b: 1, a: 1),
            outlineWidth: 8
        )
        let clip = textClip(
            content: " ",
            style: style,
            transform: Transform(topLeft: (0.2, 0.3), width: 0.6, height: 0.35)
        )

        let image = TextFrameRenderer.image(clip: clip, frame: 0, renderSize: size)
        #expect(image != nil)
        let pixels = rawPixels(image!, size: size)
        var redPixels = 0
        var bluePixels = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] > 160, pixels[i + 1] < 80, pixels[i + 2] < 80 { redPixels += 1 }
            if pixels[i] < 80, pixels[i + 1] < 80, pixels[i + 2] > 160 { bluePixels += 1 }
        }

        #expect(redPixels > 1_000, "expected visible background fill")
        #expect(bluePixels > 100, "expected visible background outline")
    }

    @Test func trackingIncreasesMeasuredTextWidth() {
        var compact = TextStyle()
        compact.shadow.enabled = false
        compact.tracking = 0
        var spaced = compact
        spaced.tracking = 12

        let compactSize = TextLayout.naturalSize(
            content: "TRACKING",
            style: compact,
            maxWidth: .greatestFiniteMagnitude,
            canvasHeight: 1080
        )
        let spacedSize = TextLayout.naturalSize(
            content: "TRACKING",
            style: spaced,
            maxWidth: .greatestFiniteMagnitude,
            canvasHeight: 1080
        )

        #expect(spacedSize.width > compactSize.width + 50)
    }

    @Test func verticalShadowOffsetExpandsMeasuredHeight() {
        var centered = TextStyle()
        centered.shadow.offsetX = 0
        centered.shadow.offsetY = 0
        var shifted = centered
        shifted.shadow.offsetY = 60

        let centeredSize = TextLayout.naturalSize(
            content: "SHADOW",
            style: centered,
            maxWidth: .greatestFiniteMagnitude,
            canvasHeight: 1080
        )
        let shiftedSize = TextLayout.naturalSize(
            content: "SHADOW",
            style: shifted,
            maxWidth: .greatestFiniteMagnitude,
            canvasHeight: 1080
        )

        #expect(shiftedSize.height > centeredSize.height + 80)
        #expect(shiftedSize.width == centeredSize.width)
    }
}
