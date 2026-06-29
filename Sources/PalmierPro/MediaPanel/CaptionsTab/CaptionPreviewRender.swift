import AppKit
import CoreImage

/// Renders a text clip as an NSImage for caption previews at backing resolution.
enum CaptionPreviewRender {
    nonisolated(unsafe) private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    static func loopFrames(_ preset: TextAnimation.Preset) -> Int { preset.renderMode == .entrance ? 28 : 54 }

    /// A synthetic text clip for preview rendering.
    static func clip(content: String, style: TextStyle, transform: Transform,
                     preset: TextAnimation.Preset, highlight: TextStyle.RGBA?) -> Clip {
        var c = Clip(mediaRef: "", startFrame: 0, durationFrames: loopFrames(preset))
        c.mediaType = .text
        c.textContent = content
        c.textStyle = style
        c.transform = transform
        c.textAnimation = TextAnimation(preset: preset, highlight: highlight)
        return c
    }

    static func nsImage(clip: Clip, frame: Int, size: CGSize, scale: CGFloat) -> NSImage? {
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        guard px.width >= 1, px.height >= 1,
              let ci = TextFrameRenderer.image(clip: clip, frame: frame, renderSize: px),
              let cg = ciContext.createCGImage(
                ci, from: CGRect(origin: .zero, size: px),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
}
