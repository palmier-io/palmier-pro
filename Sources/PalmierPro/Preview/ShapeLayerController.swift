import AVFoundation
import AppKit
import QuartzCore

/// Preview owns a long-lived `CAShapeLayer` tree with imperative properties.
/// Export hands a one-shot tree to `AVVideoCompositionCoreAnimationTool`.
@MainActor
final class ShapeLayerController {

    let shapeRoot: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.isGeometryFlipped = true
        return layer
    }()

    private var clips: [Clip] = []
    private var videoRect: CGRect = .zero
    private var layersByID: [String: CAShapeLayer] = [:]
    private var currentFrame = 0

    private static let prerollFrames = 30

    func sync(timeline: Timeline, videoRect: CGRect) {
        shapeRoot.frame = videoRect
        self.videoRect = videoRect
        clips = ShapeLayerController.visibleShapeClips(in: timeline)
        reconcile(restyle: true)
    }

    func tick(_ frame: Int) {
        currentFrame = frame
        reconcile(restyle: false)
    }

    private func reconcile(restyle: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var needed = Set<String>()
        for (index, clip) in clips.enumerated() {
            guard currentFrame >= clip.startFrame - Self.prerollFrames,
                  currentFrame < clip.endFrame else { continue }
            needed.insert(clip.id)

            let layer: CAShapeLayer
            if let existing = layersByID[clip.id] {
                layer = existing
                if restyle { Self.applyStyle(to: layer, clip: clip, containerSize: videoRect.size) }
            } else {
                layer = Self.makeShapeLayer()
                Self.applyStyle(to: layer, clip: clip, containerSize: videoRect.size)
                layersByID[clip.id] = layer
                shapeRoot.addSublayer(layer)
            }
            layer.zPosition = CGFloat(index)

            // Per-frame: position, scale, rotation, opacity, strokeEnd
            Self.applyDynamicState(to: layer, clip: clip, frame: currentFrame, containerSize: videoRect.size)

            let visible = currentFrame >= clip.startFrame
            let target: Float = visible ? Float(clip.opacityAt(frame: currentFrame)) : 0
            if layer.opacity != target { layer.opacity = target }
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
    ) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: renderSize)
        host.isGeometryFlipped = true
        host.backgroundColor = NSColor.clear.cgColor

        let fpsD = Double(max(1, fps))
        let totalSeconds = max(0.001, Double(max(1, timeline.totalFrames)) / fpsD)
        let totalFrames = max(1, Int((totalSeconds * fpsD).rounded()))

        for clip in visibleShapeClips(in: timeline) {
            let layer = makeShapeLayer()
            applyStyle(to: layer, clip: clip, containerSize: renderSize)
            // Initial state at frame 0.
            applyDynamicState(to: layer, clip: clip, frame: clip.startFrame, containerSize: renderSize)

            attachExportAnimations(
                to: layer,
                clip: clip,
                totalFrames: totalFrames,
                totalSeconds: totalSeconds,
                containerSize: renderSize
            )
            layer.displayIfNeeded()
            host.addSublayer(layer)
        }
        return host
    }

    static func buildSnapshot(
        timeline: Timeline,
        canvasSize: CGSize,
        atFrame frame: Int
    ) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: canvasSize)
        host.isGeometryFlipped = true
        for clip in visibleShapeClips(in: timeline) {
            let layer = makeShapeLayer()
            applyStyle(to: layer, clip: clip, containerSize: canvasSize)
            applyDynamicState(to: layer, clip: clip, frame: frame, containerSize: canvasSize)
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            layer.opacity = visible ? Float(clip.opacityAt(frame: frame)) : 0
            host.addSublayer(layer)
        }
        return host
    }

    // MARK: - Private

    static func visibleShapeClips(in timeline: Timeline) -> [Clip] {
        var result: [Clip] = []
        for track in timeline.tracks where !track.hidden {
            for clip in track.clips where clip.mediaType == .shape && clip.endFrame > clip.startFrame {
                result.append(clip)
            }
        }
        return result
    }

    private static func makeShapeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.fillColor = nil
        layer.strokeColor = NSColor.systemRed.cgColor
        layer.lineWidth = 6
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "transform": NSNull(),
            "strokeEnd": NSNull(),
            "strokeStart": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
            "lineDashPattern": NSNull(),
        ]
        return layer
    }

    private static let referenceCanvasHeight: CGFloat = 1080

    /// Set time-independent style: path, stroke/fill colors, line width, dash.
    /// Frame box uses the clip's STATIC transform; per-frame keyframes update
    /// position/bounds in `applyDynamicState`.
    private static func applyStyle(to layer: CAShapeLayer, clip: Clip, containerSize: CGSize) {
        let style = clip.shapeStyle ?? ShapeStyle()
        let scale = containerSize.height / referenceCanvasHeight

        let box = boundingBox(for: style, transform: clip.transform, containerSize: containerSize)
        layer.frame = box
        layer.bounds = CGRect(origin: .zero, size: box.size)

        layer.path = makePath(for: style, in: layer.bounds, scale: scale)

        layer.strokeColor = style.stroke.enabled ? style.stroke.color.nsColor.cgColor : NSColor.clear.cgColor
        layer.lineWidth = CGFloat(style.stroke.width) * scale
        layer.fillColor = style.fill.enabled ? style.fill.color.nsColor.cgColor : nil
        layer.lineDashPattern = style.stroke.dash.isEmpty
            ? nil
            : style.stroke.dash.map { NSNumber(value: $0 * Double(scale)) }
    }

    /// Per-frame state. Mirrors Clip.transformAt + opacityTrack + strokeProgressTrack.
    private static func applyDynamicState(
        to layer: CAShapeLayer,
        clip: Clip,
        frame: Int,
        containerSize: CGSize
    ) {
        // Position + size from keyframe tracks (or static transform fallback).
        let style = clip.shapeStyle ?? ShapeStyle()
        let dynamicTransform = clip.transformAt(frame: frame)
        let box = boundingBox(for: style, transform: dynamicTransform, containerSize: containerSize)

        // Rotation goes via layer.transform around the (default) anchor point.
        let rotationRadians = CGFloat(clip.rotationAt(frame: frame) * .pi / 180)
        layer.transform = CATransform3DIdentity
        layer.frame = box
        if rotationRadians != 0 {
            layer.transform = CATransform3DMakeRotation(rotationRadians, 0, 0, 1)
        }

        // Stroke draw progress.
        let progress = clip.strokeProgressTrack?.sample(at: frame - clip.startFrame, fallback: 1.0) ?? 1.0
        layer.strokeEnd = CGFloat(max(0, min(1, progress)))
        layer.strokeStart = 0
    }

    /// Bounding box for the shape, given the clip's transform & container size.
    /// Endpoint-based shapes use the endpoint bbox so rotation pivots about its center.
    private static func boundingBox(
        for style: ShapeStyle,
        transform: Transform,
        containerSize: CGSize
    ) -> CGRect {
        if let endpoints = style.endpoints {
            let bb = endpoints.boundingBox
            return CGRect(
                x: (bb.centerX - bb.width / 2) * containerSize.width,
                y: (bb.centerY - bb.height / 2) * containerSize.height,
                width: bb.width * containerSize.width,
                height: bb.height * containerSize.height
            )
        }
        let tl = transform.topLeft
        return CGRect(
            x: tl.x * containerSize.width,
            y: tl.y * containerSize.height,
            width: transform.width * containerSize.width,
            height: transform.height * containerSize.height
        )
    }

    /// CGPath for the shape inside the layer's local bounds.
    private static func makePath(for style: ShapeStyle, in bounds: CGRect, scale: CGFloat) -> CGPath {
        switch style.kind {
        case .rect:
            let r = max(0, min(0.5, style.cornerRadius)) * Double(min(bounds.width, bounds.height))
            return CGPath(roundedRect: bounds, cornerWidth: CGFloat(r), cornerHeight: CGFloat(r), transform: nil)
        case .oval:
            return CGPath(ellipseIn: bounds, transform: nil)
        case .circle:
            let side = min(bounds.width, bounds.height)
            let dx = (bounds.width - side) / 2
            let dy = (bounds.height - side) / 2
            return CGPath(ellipseIn: CGRect(x: dx, y: dy, width: side, height: side), transform: nil)
        case .line, .arrow:
            return makeLinePath(for: style, in: bounds, scale: scale, includeArrowhead: style.kind == .arrow)
        }
    }

    private static func makeLinePath(
        for style: ShapeStyle,
        in bounds: CGRect,
        scale: CGFloat,
        includeArrowhead: Bool
    ) -> CGPath {
        let path = CGMutablePath()
        guard let endpoints = style.endpoints else {
            // Fallback: diagonal across bounds.
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
            return path
        }

        let bb = endpoints.boundingBox
        let bbW = max(0.0001, bb.width)
        let bbH = max(0.0001, bb.height)
        func localPoint(x: Double, y: Double) -> CGPoint {
            let nx = (x - (bb.centerX - bb.width / 2)) / bbW
            let ny = (y - (bb.centerY - bb.height / 2)) / bbH
            return CGPoint(x: CGFloat(nx) * bounds.width, y: CGFloat(ny) * bounds.height)
        }

        let from = localPoint(x: endpoints.fromX, y: endpoints.fromY)
        let to = localPoint(x: endpoints.toX, y: endpoints.toY)

        path.move(to: from)
        if let cx = endpoints.controlX, let cy = endpoints.controlY {
            let control = localPoint(x: cx, y: cy)
            path.addQuadCurve(to: to, control: control)
        } else {
            path.addLine(to: to)
        }

        if includeArrowhead && style.arrowhead.style != .none {
            appendArrowhead(to: path, tip: to, base: from, style: style.arrowhead, scale: scale)
        }
        return path
    }

    private static func appendArrowhead(
        to path: CGMutablePath,
        tip: CGPoint,
        base: CGPoint,
        style: ShapeStyle.Arrowhead,
        scale: CGFloat
    ) {
        let dx = tip.x - base.x
        let dy = tip.y - base.y
        let length = max(0.001, sqrt(dx * dx + dy * dy))
        let ux = dx / length
        let uy = dy / length
        // Perpendicular unit vector.
        let px = -uy
        let py = ux

        let size = CGFloat(style.size) * scale
        let backX = tip.x - ux * size
        let backY = tip.y - uy * size
        let halfWidth = size * 0.6

        let left = CGPoint(x: backX + px * halfWidth, y: backY + py * halfWidth)
        let right = CGPoint(x: backX - px * halfWidth, y: backY - py * halfWidth)

        switch style.style {
        case .triangle:
            path.move(to: tip)
            path.addLine(to: left)
            path.addLine(to: right)
            path.closeSubpath()
        case .open:
            path.move(to: left)
            path.addLine(to: tip)
            path.addLine(to: right)
        case .none:
            break
        }
    }

    // MARK: - Export animation bake

    private static func attachExportAnimations(
        to layer: CAShapeLayer,
        clip: Clip,
        totalFrames: Int,
        totalSeconds: Double,
        containerSize: CGSize
    ) {
        guard totalFrames > 0 else { return }

        var opacityValues: [NSNumber] = []
        var strokeEndValues: [NSNumber] = []
        var positionValues: [NSValue] = []
        var boundsValues: [NSValue] = []
        var transformValues: [NSValue] = []
        var keyTimes: [NSNumber] = [NSNumber(value: 0)]

        let style = clip.shapeStyle ?? ShapeStyle()
        for frame in 0..<totalFrames {
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            let v = visible ? clip.opacityAt(frame: frame) : 0
            opacityValues.append(NSNumber(value: Float(v)))

            let progress = clip.strokeProgressTrack?.sample(at: frame - clip.startFrame, fallback: 1.0) ?? 1.0
            strokeEndValues.append(NSNumber(value: Float(max(0, min(1, progress)))))

            let dynTransform = clip.transformAt(frame: frame)
            let box = boundingBox(for: style, transform: dynTransform, containerSize: containerSize)
            // position = center of frame in parent coords; bounds = layer-local size
            positionValues.append(NSValue(point: NSPoint(x: box.midX, y: box.midY)))
            boundsValues.append(NSValue(rect: NSRect(origin: .zero, size: box.size)))
            let rotation = clip.rotationAt(frame: frame) * .pi / 180
            transformValues.append(NSValue(caTransform3D: CATransform3DMakeRotation(CGFloat(rotation), 0, 0, 1)))

            keyTimes.append(NSNumber(value: Double(frame + 1) / Double(totalFrames)))
        }

        // Opacity
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.calculationMode = .discrete
        opacity.values = opacityValues
        opacity.keyTimes = keyTimes
        opacity.beginTime = AVCoreAnimationBeginTimeAtZero
        opacity.duration = totalSeconds
        opacity.fillMode = .both
        opacity.isRemovedOnCompletion = false
        layer.add(opacity, forKey: "opacity")

        // Stroke draw
        let stroke = CAKeyframeAnimation(keyPath: "strokeEnd")
        stroke.calculationMode = .discrete
        stroke.values = strokeEndValues
        stroke.keyTimes = keyTimes
        stroke.beginTime = AVCoreAnimationBeginTimeAtZero
        stroke.duration = totalSeconds
        stroke.fillMode = .both
        stroke.isRemovedOnCompletion = false
        layer.add(stroke, forKey: "strokeEnd")

        // Position
        let position = CAKeyframeAnimation(keyPath: "position")
        position.calculationMode = .discrete
        position.values = positionValues
        position.keyTimes = keyTimes
        position.beginTime = AVCoreAnimationBeginTimeAtZero
        position.duration = totalSeconds
        position.fillMode = .both
        position.isRemovedOnCompletion = false
        layer.add(position, forKey: "position")

        // Bounds (for scale changes)
        let boundsAnim = CAKeyframeAnimation(keyPath: "bounds")
        boundsAnim.calculationMode = .discrete
        boundsAnim.values = boundsValues
        boundsAnim.keyTimes = keyTimes
        boundsAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        boundsAnim.duration = totalSeconds
        boundsAnim.fillMode = .both
        boundsAnim.isRemovedOnCompletion = false
        layer.add(boundsAnim, forKey: "bounds")

        // Rotation
        let rotation = CAKeyframeAnimation(keyPath: "transform")
        rotation.calculationMode = .discrete
        rotation.values = transformValues
        rotation.keyTimes = keyTimes
        rotation.beginTime = AVCoreAnimationBeginTimeAtZero
        rotation.duration = totalSeconds
        rotation.fillMode = .both
        rotation.isRemovedOnCompletion = false
        layer.add(rotation, forKey: "transform")
    }
}
