import AppKit
import SwiftUI

/// Loops the selected caption animation in the Captions tab preview.
struct CaptionAnimatedPreview: View {
    let text: String
    let style: TextStyle
    let center: CGPoint
    let preset: TextAnimation.Preset
    var highlight: TextStyle.RGBA? = nil
    let canvas: CGSize
    let size: CGSize

    @State private var start = Date()
    @Environment(\.displayScale) private var displayScale

    private static let fps = 30

    var body: some View {
        if preset == .none {
            frameView(at: 0)   // static — render once, no loop
        } else {
            SwiftUI.TimelineView(.periodic(from: start, by: 1.0 / Double(Self.fps))) { ctx in
                frameView(at: Int(ctx.date.timeIntervalSince(start) * Double(Self.fps)) % CaptionPreviewRender.loopFrames(preset))
            }
        }
    }

    @ViewBuilder
    private func frameView(at frame: Int) -> some View {
        if let img = CaptionPreviewRender.nsImage(clip: previewClip, frame: frame, size: size, scale: max(1, displayScale)) {
            Image(nsImage: img)
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        } else {
            Color.clear
        }
    }

    private var previewClip: Clip {
        let natural = TextLayout.naturalSize(
            content: text, style: style,
            maxWidth: canvas.width * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio,
            canvasHeight: canvas.height
        )
        let transform = Transform(
            centerX: center.x, centerY: center.y,
            width: natural.width / canvas.width, height: natural.height / canvas.height
        )
        return CaptionPreviewRender.clip(content: text, style: style, transform: transform, preset: preset, highlight: highlight)
    }
}
