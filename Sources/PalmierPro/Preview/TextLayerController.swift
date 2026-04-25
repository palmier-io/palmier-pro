import AVFoundation
import AppKit
import QuartzCore

/// Preview owns a long-lived `CATextLayer` tree with imperative opacity;
/// export hands a one-shot tree to `AVVideoCompositionCoreAnimationTool`.
@MainActor
final class TextLayerController {

    let textRoot: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.isGeometryFlipped = true
        return layer
    }()

    private var clips: [Clip] = []

    func sync(timeline: Timeline, canvasSize: CGSize, videoRect: CGRect) {
        textRoot.frame = videoRect
        let visible = TextLayerController.visibleTextClips(in: timeline)

        let existing = textRoot.sublayers ?? []
        let needed = visible.count

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if existing.count > needed {
            for layer in existing.suffix(existing.count - needed) {
                layer.removeFromSuperlayer()
            }
        } else if existing.count < needed {
            for _ in 0..<(needed - existing.count) {
                textRoot.addSublayer(TextLayerController.makeTextLayer())
            }
        }

        let updated = textRoot.sublayers ?? []
        for (clip, sublayer) in zip(visible, updated) {
            guard let layer = sublayer as? CATextLayer else { continue }
            TextLayerController.applyStyle(to: layer, clip: clip, containerSize: videoRect.size, canvasSize: canvasSize)
        }

        CATransaction.commit()

        clips = visible
    }

    func tick(_ frame: Int) {
        let sublayers = textRoot.sublayers ?? []
        guard sublayers.count == clips.count else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (clip, layer) in zip(clips, sublayers) {
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            let target: Float = visible ? Float(clip.opacity) : 0
            if layer.opacity != target { layer.opacity = target }
        }
        CATransaction.commit()
    }

    // MARK: - Static builders

    static func buildForExport(
        timeline: Timeline,
        fps: Int,
        canvasSize: CGSize
    ) -> (parent: CALayer, videoLayer: CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: canvasSize)
        parent.isGeometryFlipped = true
        parent.backgroundColor = NSColor.clear.cgColor
        parent.beginTime = AVCoreAnimationBeginTimeAtZero

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)

        let fpsD = Double(max(1, fps))
        let totalSeconds = max(0.001, Double(max(1, timeline.totalFrames)) / fpsD)
        for clip in visibleTextClips(in: timeline) {
            let layer = makeTextLayer()
            applyStyle(to: layer, clip: clip, containerSize: canvasSize, canvasSize: canvasSize)
            applyOpacityAnimation(to: layer, clip: clip, fps: fps, totalSeconds: totalSeconds)
            parent.addSublayer(layer)
        }
        return (parent, videoLayer)
    }

    static func buildSnapshot(
        timeline: Timeline,
        canvasSize: CGSize,
        atFrame frame: Int
    ) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: canvasSize)
        host.isGeometryFlipped = true
        for clip in visibleTextClips(in: timeline) {
            let layer = makeTextLayer()
            applyStyle(to: layer, clip: clip, containerSize: canvasSize, canvasSize: canvasSize)
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            layer.opacity = visible ? Float(clip.opacity) : 0
            host.addSublayer(layer)
        }
        return host
    }

    // MARK: - Private

    private static func visibleTextClips(in timeline: Timeline) -> [Clip] {
        var result: [Clip] = []
        for track in timeline.tracks where !track.hidden {
            for clip in track.clips where clip.mediaType == .text && clip.endFrame > clip.startFrame {
                result.append(clip)
            }
        }
        return result
    }

    private static func makeTextLayer() -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.allowsFontSubpixelQuantization = true
        // NSNull suppresses CATextLayer's implicit per-property cross-fade.
        layer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "transform": NSNull(),
            "string": NSNull(),
        ]
        return layer
    }

    private static func applyStyle(to layer: CATextLayer, clip: Clip, containerSize: CGSize, canvasSize: CGSize) {
        let style = clip.textStyle ?? TextStyle()
        let content = clip.textContent ?? ""
        let scaleX = containerSize.width / max(1, canvasSize.width)
        let scaleY = containerSize.height / max(1, canvasSize.height)
        let minScale = min(scaleX, scaleY)

        let tl = clip.transform.topLeft
        layer.frame = CGRect(
            x: tl.x * containerSize.width,
            y: tl.y * containerSize.height,
            width: clip.transform.width * containerSize.width,
            height: clip.transform.height * containerSize.height
        )

        let fontSize = CGFloat(style.fontSize * style.fontScale) * minScale
        layer.string = NSAttributedString(
            string: content,
            attributes: style.attributes(size: fontSize)
        )
        layer.alignmentMode = style.alignment.caTextAlignmentMode

        if style.shadow.enabled {
            layer.shadowColor = style.shadow.color.nsColor.cgColor
            layer.shadowOpacity = 1
            layer.shadowOffset = CGSize(
                width: style.shadow.offsetX * minScale,
                height: style.shadow.offsetY * minScale
            )
            layer.shadowRadius = max(0, CGFloat(style.shadow.blur) * minScale)
        } else {
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
        }
    }

    /// `AVVideoCompositionCoreAnimationTool` ignores the model `opacity` on
    /// early frames, so visibility must come from animations. `.both` on "on"
    /// covers t=0 via backward fill; later-added "off" wins after `endFrame`.
    private static func applyOpacityAnimation(
        to layer: CATextLayer,
        clip: Clip,
        fps: Int,
        totalSeconds: Double
    ) {
        let fpsD = Double(max(1, fps))
        let opacity = Float(clip.opacity)
        let startSec = Double(clip.startFrame) / fpsD
        let endSec = min(totalSeconds, Double(clip.endFrame) / fpsD)

        let onAnim = CABasicAnimation(keyPath: "opacity")
        onAnim.fromValue = opacity
        onAnim.toValue = opacity
        onAnim.beginTime = clip.startFrame > 0 ? startSec : AVCoreAnimationBeginTimeAtZero
        onAnim.duration = max(0.001, endSec - startSec)
        onAnim.fillMode = clip.startFrame > 0 ? .forwards : .both
        onAnim.isRemovedOnCompletion = false
        layer.add(onAnim, forKey: "on")

        let remaining = totalSeconds - endSec
        if remaining > 0 {
            let offAnim = CABasicAnimation(keyPath: "opacity")
            offAnim.fromValue = 0
            offAnim.toValue = 0
            offAnim.beginTime = endSec
            offAnim.duration = remaining
            offAnim.fillMode = .forwards
            offAnim.isRemovedOnCompletion = false
            layer.add(offAnim, forKey: "off")
        }
    }
}
