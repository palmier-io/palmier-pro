import AVFoundation
import AppKit
import QuartzCore

/// Owns the preview's `CATextLayer` tree (direct sublayer of `PreviewNSView`).
/// Preview opacity is set imperatively from `currentFrame`; export uses
/// `AVVideoCompositionCoreAnimationTool` with a freshly built keyframed tree.
@MainActor
final class TextLayerController {

    /// Kept alive across item swaps; `PreviewNSView.layout()` tracks its frame to `videoRect`.
    let textRoot: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.isGeometryFlipped = true
        return layer
    }()

    private var layers: [String: CATextLayer] = [:]
    private var visibilityCache: [String: (startFrame: Int, endFrame: Int, opacity: Double)] = [:]

    // Cached for frame-only ticks that don't carry timeline context.
    private var cachedCanvasSize: CGSize = CGSize(width: 1920, height: 1080)
    private var cachedVideoRect: CGRect = .zero
    private var cachedFPS: Int = 30

    // MARK: - Public API

    /// Diff the layer tree against `timeline`, then refresh visibility at `currentFrame`.
    func sync(timeline: Timeline, fps: Int, canvasSize: CGSize, videoRect: CGRect, currentFrame: Int) {
        cachedFPS = max(1, fps)
        cachedCanvasSize = canvasSize
        cachedVideoRect = videoRect
        textRoot.frame = videoRect
        apply(timeline: timeline)
        updateFrameVisibility(currentFrame)
    }

    /// Flip each layer's opacity to match visibility at `frame` — driven by the time observer and seek.
    func updateFrameVisibility(_ frame: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, timing) in visibilityCache {
            guard let layer = layers[id] else { continue }
            let visible = frame >= timing.startFrame && frame < timing.endFrame
            let opacity = visible ? Float(timing.opacity) : 0
            if layer.opacity != opacity {
                layer.opacity = opacity
            }
        }
        CATransaction.commit()
    }

    /// Standalone tree for `AVVideoCompositionCoreAnimationTool` — opacity is
    /// keyframed because the tool reads the animation timeline from the layers.
    func buildForExport(timeline: Timeline, fps: Int, canvasSize: CGSize) -> (parent: CALayer, videoLayer: CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: canvasSize)
        parent.isGeometryFlipped = true
        parent.backgroundColor = NSColor.clear.cgColor

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)

        let previousCanvas = cachedCanvasSize
        let previousRect = cachedVideoRect
        cachedCanvasSize = canvasSize
        cachedVideoRect = CGRect(origin: .zero, size: canvasSize)
        defer {
            cachedCanvasSize = previousCanvas
            cachedVideoRect = previousRect
        }

        for clip in visibleTextClips(timeline: timeline) {
            let layer = makeTextLayer()
            applyStyle(to: layer, clip: clip, containerSize: canvasSize)
            applyExportOpacity(to: layer, clip: clip, fps: fps)
            parent.addSublayer(layer)
        }
        return (parent, videoLayer)
    }

    // MARK: - Private

    private func apply(timeline: Timeline) {
        let desiredClips = visibleTextClips(timeline: timeline)
        let desiredIds = Set(desiredClips.map(\.id))
        let existingIds = Set(layers.keys)

        for removed in existingIds.subtracting(desiredIds) {
            layers[removed]?.removeFromSuperlayer()
            layers.removeValue(forKey: removed)
            visibilityCache.removeValue(forKey: removed)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for clip in desiredClips {
            let layer: CATextLayer
            if let existing = layers[clip.id] {
                layer = existing
            } else {
                layer = makeTextLayer()
                textRoot.addSublayer(layer)
                layers[clip.id] = layer
            }
            applyStyle(to: layer, clip: clip, containerSize: cachedVideoRect.size)
            visibilityCache[clip.id] = (clip.startFrame, clip.endFrame, clip.opacity)
        }

        CATransaction.commit()
    }

    private func visibleTextClips(timeline: Timeline) -> [Clip] {
        var result: [Clip] = []
        for track in timeline.tracks where !track.hidden {
            for clip in track.clips where clip.mediaType == .text {
                result.append(clip)
            }
        }
        return result
    }

    private func makeTextLayer() -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.isWrapped = true
        // Scale rounding can shave a glyph; grow-to-fit handles the common case.
        layer.truncationMode = .none
        layer.allowsFontSubpixelQuantization = true
        // NSNull suppresses CATextLayer's implicit cross-fade per-layer (not just per-transaction).
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

    private func applyStyle(to layer: CATextLayer, clip: Clip, containerSize: CGSize) {
        let style = clip.textStyle ?? TextStyle()
        let content = clip.textContent ?? ""
        let scaleX = containerSize.width / max(1, cachedCanvasSize.width)
        let scaleY = containerSize.height / max(1, cachedCanvasSize.height)
        let minScale = min(scaleX, scaleY)

        let tl = clip.transform.topLeft
        layer.frame = CGRect(
            x: tl.x * containerSize.width,
            y: tl.y * containerSize.height,
            width: clip.transform.width * containerSize.width,
            height: clip.transform.height * containerSize.height
        )

        let fontSize = CGFloat(style.fontSize) * minScale
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

    /// Model opacity = 0 (hidden); animation holds `clip.opacity` through the
    /// clip range; `.removed` fill reverts to model outside it.
    private func applyExportOpacity(to layer: CATextLayer, clip: Clip, fps: Int) {
        layer.opacity = 0
        let fpsD = Double(max(1, fps))
        let startSeconds = Double(clip.startFrame) / fpsD
        let durationSeconds = max(0.001, Double(max(0, clip.endFrame - clip.startFrame)) / fpsD)

        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = Float(clip.opacity)
        anim.toValue = Float(clip.opacity)
        anim.duration = durationSeconds
        // CA treats 0 as CACurrentMediaTime(); use the sentinel for composition-time zero.
        anim.beginTime = startSeconds > 0 ? startSeconds : AVCoreAnimationBeginTimeAtZero
        anim.fillMode = .removed
        anim.isRemovedOnCompletion = false

        layer.add(anim, forKey: "opacity")
    }
}
