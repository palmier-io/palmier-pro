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
}
