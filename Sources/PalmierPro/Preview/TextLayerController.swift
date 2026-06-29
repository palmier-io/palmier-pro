import AVFoundation
import AppKit
import QuartzCore

/// Preview owns a long-lived text layer tree with imperative opacity;
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
    private var videoRect: CGRect = .zero
    private var layersByID: [String: CALayer] = [:]
    private var currentFrame = 0

    // Materialize layers slightly early so playback never hitches on typesetting.
    private static let prerollFrames = 30

    func sync(timeline: Timeline, videoRect: CGRect) {
        textRoot.frame = videoRect
        self.videoRect = videoRect
        clips = TextLayerController.visibleTextClips(in: timeline)
        reconcile(restyle: true)
    }

    func tick(_ frame: Int) {
        currentFrame = frame
        reconcile(restyle: false)
    }

    // Only clips within the preroll window own layers; everything else stays unmaterialized.
    private func reconcile(restyle: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var needed = Set<String>()
        for (index, clip) in clips.enumerated() {
            guard currentFrame >= clip.startFrame - Self.prerollFrames,
                  currentFrame < clip.endFrame else { continue }
            needed.insert(clip.id)

            let layer: CALayer
            if let existing = layersByID[clip.id] {
                layer = existing
                if restyle { Self.rebuildClipLayer(layer, clip: clip, containerSize: videoRect.size) }
            } else {
                layer = Self.makeClipLayer(clip: clip, containerSize: videoRect.size)
                layersByID[clip.id] = layer
                textRoot.addSublayer(layer)
            }
            layer.zPosition = CGFloat(index)
            Self.updateClipLayer(layer, clip: clip, frame: currentFrame, containerSize: videoRect.size)
        }

        for (id, layer) in layersByID where !needed.contains(id) {
            layer.removeFromSuperlayer()
            layersByID[id] = nil
        }

        CATransaction.commit()
    }

    // MARK: - Static builders

    static func buildForExport(
        timeline: Timeline,
        fps: Int,
        renderSize: CGSize
    ) -> (parent: CALayer, videoLayer: CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true
        parent.backgroundColor = NSColor.clear.cgColor
        parent.beginTime = AVCoreAnimationBeginTimeAtZero

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)

        let fpsD = Double(max(1, fps))
        let totalSeconds = max(0.001, Double(max(1, timeline.totalFrames)) / fpsD)
        for clip in visibleTextClips(in: timeline) {
            let layer = makeClipLayer(clip: clip, containerSize: renderSize)
            if usesCaptionWords(clip) {
                applyAnimatedClipExport(to: layer, clip: clip, fps: fps, totalSeconds: totalSeconds, containerSize: renderSize)
            } else {
                applyOpacityAnimation(to: layer, clip: clip, fps: fps, totalSeconds: totalSeconds)
            }
            displayTextTree(layer)
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
            let layer = makeClipLayer(clip: clip, containerSize: canvasSize)
            updateClipLayer(layer, clip: clip, frame: frame, containerSize: canvasSize)
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

    private static func usesCaptionWords(_ clip: Clip) -> Bool {
        clip.captionWords?.isEmpty == false
    }

    private static func makeClipLayer(clip: Clip, containerSize: CGSize) -> CALayer {
        if usesCaptionWords(clip) {
            return makeAnimatedClipLayer(clip: clip, containerSize: containerSize)
        }
        return makeStaticClipLayer(clip: clip, containerSize: containerSize)
    }

    private static func rebuildClipLayer(_ layer: CALayer, clip: Clip, containerSize: CGSize) {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        if usesCaptionWords(clip) {
            configureAnimatedClipLayer(layer, clip: clip, containerSize: containerSize)
        } else {
            configureStaticClipLayer(layer, clip: clip, containerSize: containerSize)
        }
    }

    private static func updateClipLayer(_ layer: CALayer, clip: Clip, frame: Int, containerSize: CGSize) {
        let visible = frame >= clip.startFrame && frame < clip.endFrame
        let clipOpacity = visible ? Float(clip.opacityAt(frame: frame)) : 0
        if usesCaptionWords(clip) {
            layer.opacity = clipOpacity
            guard visible, let words = clip.captionWords else { return }
            let animation = clip.captionWordAnimation ?? .none
            let relFrame = frame - clip.startFrame
            let wordLayers = layer.sublayers ?? []
            for (index, word) in words.enumerated() where index < wordLayers.count {
                applyWordAppearance(
                    to: wordLayers[index],
                    animation: animation,
                    relFrame: relFrame,
                    word: word
                )
            }
        } else {
            layer.opacity = clipOpacity
        }
    }

    private static func makeTextLayer() -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.allowsFontSubpixelQuantization = true
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

    private static func makeBaseLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "transform": NSNull(),
        ]
        return layer
    }

    private static let referenceCanvasHeight: CGFloat = 1080

    private static func clipBoxFrame(clip: Clip, containerSize: CGSize) -> CGRect {
        let tl = clip.transform.topLeft
        return CGRect(
            x: tl.x * containerSize.width,
            y: tl.y * containerSize.height,
            width: clip.transform.width * containerSize.width,
            height: clip.transform.height * containerSize.height
        )
    }

    private static func makeStaticClipLayer(clip: Clip, containerSize: CGSize) -> CALayer {
        let layer = makeBaseLayer()
        configureStaticClipLayer(layer, clip: clip, containerSize: containerSize)
        return layer
    }

    private static func configureStaticClipLayer(_ layer: CALayer, clip: Clip, containerSize: CGSize) {
        let style = clip.textStyle ?? TextStyle()
        let scale = containerSize.height / referenceCanvasHeight
        layer.frame = clipBoxFrame(clip: clip, containerSize: containerSize)
        applyBoxChrome(to: layer, style: style, scale: scale)

        let fontSize = CGFloat(style.fontSize * style.fontScale) * scale
        addTextContent(
            to: layer,
            content: clip.textContent ?? "",
            style: style,
            fontSize: fontSize,
            alignment: style.alignment.caTextAlignmentMode,
            wrapped: true,
            shadowOnFill: true,
            scale: scale
        )
    }

    private static func addTextContent(
        to container: CALayer,
        content: String,
        style: TextStyle,
        fontSize: CGFloat,
        alignment: CATextLayerAlignmentMode,
        wrapped: Bool,
        shadowOnFill: Bool,
        scale: CGFloat
    ) {
        let fill = makeTextLayer()
        fill.isWrapped = wrapped
        fill.frame = CGRect(origin: .zero, size: container.bounds.size)
        fill.string = NSAttributedString(string: content, attributes: style.fillAttributes(size: fontSize))
        fill.alignmentMode = alignment
        if shadowOnFill { applyWordShadow(to: fill, style: style, scale: scale) }
        container.addSublayer(fill)
    }

    private static func addWordContent(
        to wordHost: CALayer,
        content: String,
        style: TextStyle,
        fontSize: CGFloat,
        glyphRect: CGRect,
        shadowOnFill: Bool,
        scale: CGFloat
    ) {
        let fill = makeTextLayer()
        fill.isWrapped = false
        fill.frame = CGRect(origin: .zero, size: glyphRect.size)
        fill.alignmentMode = .left
        fill.string = style.wordFillString(content: content, size: fontSize)
        if shadowOnFill { applyWordShadow(to: fill, style: style, scale: scale) }
        wordHost.addSublayer(fill)
    }

    private static func makeAnimatedClipLayer(clip: Clip, containerSize: CGSize) -> CALayer {
        let layer = makeBaseLayer()
        configureAnimatedClipLayer(layer, clip: clip, containerSize: containerSize)
        return layer
    }

    private static func configureAnimatedClipLayer(_ layer: CALayer, clip: Clip, containerSize: CGSize) {
        let style = clip.textStyle ?? TextStyle()
        let scale = containerSize.height / referenceCanvasHeight
        let box = clipBoxFrame(clip: clip, containerSize: containerSize)
        layer.frame = box

        layer.backgroundColor = style.background.enabled ? style.background.color.nsColor.cgColor : nil
        layer.borderColor = style.border.enabled ? style.border.color.nsColor.cgColor : nil
        layer.borderWidth = style.border.enabled ? AppTheme.BorderWidth.thin * scale : 0

        guard let words = clip.captionWords else { return }
        let wordFrames = TextLayout.wordFrames(
            content: clip.textContent ?? "",
            words: words,
            style: style,
            boxSize: box.size,
            canvasHeight: containerSize.height
        )
        let fontSize = CGFloat(style.fontSize * style.fontScale) * scale
        for (index, layout) in wordFrames.enumerated() where index < words.count {
            let wordHost = makeBaseLayer()
            wordHost.frame = layout.rect
            addWordContent(
                to: wordHost,
                content: layout.text,
                style: style,
                fontSize: fontSize,
                glyphRect: layout.rect,
                shadowOnFill: true,
                scale: scale
            )
            layer.addSublayer(wordHost)
        }
    }

    private static func applyBoxChrome(to layer: CALayer, style: TextStyle, scale: CGFloat) {
        layer.backgroundColor = style.background.enabled ? style.background.color.nsColor.cgColor : nil
        layer.borderColor = style.border.enabled ? style.border.color.nsColor.cgColor : nil
        layer.borderWidth = style.border.enabled ? AppTheme.BorderWidth.thin * scale : 0
    }

    private static func applyWordShadow(to layer: CATextLayer, style: TextStyle, scale: CGFloat) {
        if style.shadow.enabled {
            layer.shadowColor = style.shadow.color.nsColor.cgColor
            layer.shadowOpacity = 1
            layer.shadowOffset = CGSize(
                width: style.shadow.offsetX * scale,
                height: style.shadow.offsetY * scale
            )
            layer.shadowRadius = max(0, CGFloat(style.shadow.blur) * scale)
        } else {
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
        }
    }

    private static func applyWordAppearance(
        to layer: CALayer,
        animation: CaptionWordAnimation,
        relFrame: Int,
        word: CaptionWordTiming
    ) {
        let appearance = animation.appearance(at: relFrame, wordStartFrame: word.startFrame)
        layer.opacity = appearance.opacity
        let offsetY = animation.verticalOffset(at: relFrame, wordStartFrame: word.startFrame) * layer.bounds.height
        layer.setAffineTransform(
            CGAffineTransform(translationX: 0, y: offsetY)
                .scaledBy(x: appearance.scale, y: appearance.scale)
        )
    }

    private static func applyAnimatedClipExport(
        to layer: CALayer,
        clip: Clip,
        fps: Int,
        totalSeconds: Double,
        containerSize: CGSize
    ) {
        applyOpacityAnimation(to: layer, clip: clip, fps: fps, totalSeconds: totalSeconds)
        guard let words = clip.captionWords, !words.isEmpty else { return }
        let animation = clip.captionWordAnimation ?? .none
        let wordLayers = layer.sublayers ?? []
        for (index, word) in words.enumerated() where index < wordLayers.count {
            applyWordExportAnimation(
                to: wordLayers[index],
                clip: clip,
                word: word,
                animation: animation,
                fps: fps,
                totalSeconds: totalSeconds
            )
        }
    }

    private static func applyWordExportAnimation(
        to layer: CALayer,
        clip: Clip,
        word: CaptionWordTiming,
        animation: CaptionWordAnimation,
        fps: Int,
        totalSeconds: Double
    ) {
        let fpsD = Double(max(1, fps))
        let total = max(0.001, totalSeconds)
        let totalFrames = max(1, Int((total * fpsD).rounded()))

        var opacityTimes: [NSNumber] = [NSNumber(value: 0)]
        var opacityValues: [NSNumber] = []
        var scaleTimes: [NSNumber] = [NSNumber(value: 0)]
        var scaleValues: [NSNumber] = []
        var offsetTimes: [NSNumber] = [NSNumber(value: 0)]
        var offsetValues: [NSNumber] = []

        for frame in 0..<totalFrames {
            let inClip = frame >= clip.startFrame && frame < clip.endFrame
            let relFrame = inClip ? frame - clip.startFrame : -1
            let appearance = inClip
                ? animation.appearance(at: relFrame, wordStartFrame: word.startFrame)
                : (scale: CGFloat(0.55), opacity: Float(0))
            let offsetY = inClip
                ? animation.verticalOffset(at: relFrame, wordStartFrame: word.startFrame) * layer.bounds.height
                : 0

            opacityValues.append(NSNumber(value: appearance.opacity))
            opacityTimes.append(NSNumber(value: Double(frame + 1) / Double(totalFrames)))
            scaleValues.append(NSNumber(value: Float(appearance.scale)))
            scaleTimes.append(NSNumber(value: Double(frame + 1) / Double(totalFrames)))
            offsetValues.append(NSNumber(value: Float(offsetY)))
            offsetTimes.append(NSNumber(value: Double(frame + 1) / Double(totalFrames)))
        }

        layer.opacity = 0
        addDiscreteAnimation(to: layer, keyPath: "opacity", values: opacityValues, keyTimes: opacityTimes, duration: total)
        addDiscreteAnimation(to: layer, keyPath: "transform.scale", values: scaleValues, keyTimes: scaleTimes, duration: total)
        if animation == .fadeUp {
            addDiscreteAnimation(to: layer, keyPath: "transform.translation.y", values: offsetValues, keyTimes: offsetTimes, duration: total)
        }
    }

    private static func displayTextTree(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach { displayTextTree($0) }
    }

    private static func addDiscreteAnimation(
        to layer: CALayer,
        keyPath: String,
        values: [NSNumber],
        keyTimes: [NSNumber],
        duration: Double
    ) {
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.calculationMode = .discrete
        anim.values = values
        anim.keyTimes = keyTimes
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = duration
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: keyPath)
    }

    /// Export-time opacity for a whole clip or static text layer.
    private static func applyOpacityAnimation(
        to layer: CALayer,
        clip: Clip,
        fps: Int,
        totalSeconds: Double
    ) {
        let fpsD = Double(max(1, fps))
        let total = max(0.001, totalSeconds)
        let totalFrames = max(1, Int((total * fpsD).rounded()))

        layer.opacity = 0

        var keyTimes: [NSNumber] = [NSNumber(value: 0)]
        var values: [NSNumber] = []
        for frame in 0..<totalFrames {
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            let v = visible ? clip.opacityAt(frame: frame) : 0
            values.append(NSNumber(value: Float(v)))
            keyTimes.append(NSNumber(value: Double(frame + 1) / Double(totalFrames)))
        }

        addDiscreteAnimation(to: layer, keyPath: "opacity", values: values, keyTimes: keyTimes, duration: total)
    }
}
