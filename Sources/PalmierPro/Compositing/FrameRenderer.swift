import AVFoundation
import CoreImage

/// Composites a frame from a CompositorInstruction's layers with Core Image:
/// per-layer crop → effects → transform → opacity, stacked bottom→top.
enum FrameRenderer {

    static func render(
        instruction: CompositorInstruction,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        compositionTime: CMTime,
        into output: CVPixelBuffer,
        context: CIContext
    ) {
        let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
        let frame = Int((compositionTime.seconds * Double(instruction.fps)).rounded())

        let base = CIImage(color: .black).cropped(to: renderRect)
        var accum = composite(
            layers: instruction.layers, over: base, frame: frame,
            renderSize: instruction.renderSize, sourceFrame: sourceFrame, gateByClipRange: false
        )
        if let ratio = instruction.letterboxRatio, ratio > 0 {
            let canvasAspect = renderRect.width / renderRect.height
            if ratio > canvasAspect {
                // Letterbox: horizontal bars top and bottom
                let barH = max(0, (renderRect.height - renderRect.width / ratio) / 2)
                let black = CIImage(color: .black)
                let bottom = black.cropped(to: CGRect(x: 0, y: 0, width: renderRect.width, height: barH))
                let top = black.cropped(to: CGRect(x: 0, y: renderRect.height - barH, width: renderRect.width, height: barH))
                accum = bottom.composited(over: accum)
                accum = top.composited(over: accum)
            } else if ratio < canvasAspect {
                // Pillarbox: vertical bars left and right
                let barW = max(0, (renderRect.width - renderRect.height * ratio) / 2)
                let black = CIImage(color: .black)
                let left = black.cropped(to: CGRect(x: 0, y: 0, width: barW, height: renderRect.height))
                let right = black.cropped(to: CGRect(x: renderRect.width - barW, y: 0, width: barW, height: renderRect.height))
                accum = left.composited(over: accum)
                accum = right.composited(over: accum)
            }
        }
        context.render(accum, to: output, bounds: renderRect, colorSpace: nil)
        tag709(output)
    }

    /// Bottom→top layer stack; `gateByClipRange` skips group children outside `frame`.
    private static func composite(
        layers: [LayerPlan],
        over background: CIImage,
        frame: Int,
        renderSize: CGSize,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        gateByClipRange: Bool
    ) -> CIImage {
        var accum = background
        for layer in layers {
            if gateByClipRange, !layer.clip.contains(timelineFrame: frame) { continue }
            let mode = layer.clip.blendMode ?? .normal
            // Source-over bakes opacity into alpha; blend modes apply it as a fade of
            // the blend RESULT (Photoshop/Premiere semantics), so don't bake it there.
            let isNormal = mode.ciFilterName == nil
            let image: CIImage?
            switch layer.source {
            case .track(let id):
                guard let buffer = sourceFrame(id) else { continue }
                image = composedLayer(layer, buffer: buffer, frame: frame,
                                      renderSize: renderSize, bakeOpacity: isNormal)
            case .text:
                image = composedTextLayer(layer, frame: frame, renderSize: renderSize,
                                          bakeOpacity: isNormal)
            case .adjustment:
                // Adjustment layers apply their effects onto the composited result so far.
                accum = applyAdjustmentLayer(layer, accum: accum, frame: frame)
                continue
            case .group(let children, let canvas):
                image = composedGroupLayer(layer, children: children, canvas: canvas, frame: frame,
                                           renderSize: renderSize, sourceFrame: sourceFrame, bakeOpacity: isNormal)
            }
            guard let image else { continue }
            if isNormal {
                accum = image.composited(over: accum)
            } else {
                let opacity = min(1.0, max(0.0, layer.clip.opacityAt(frame: frame)))
                accum = blend(image, over: accum, filter: mode.ciFilterName!, opacity: opacity)
            }
        }
        return accum
    }

    /// Children composite at the child canvas; the nest clip's pipeline runs on the result.
    private static func composedGroupLayer(
        _ layer: LayerPlan,
        children: [LayerPlan],
        canvas: CGSize,
        frame: Int,
        renderSize: CGSize,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        bakeOpacity: Bool
    ) -> CIImage? {
        let alpha = min(1.0, max(0.0, layer.clip.opacityAt(frame: frame)))
        guard alpha > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let base = CIImage(color: .black).cropped(to: canvasRect)
        let intermediate = composite(
            layers: children, over: base, frame: frame,
            renderSize: canvas, sourceFrame: sourceFrame, gateByClipRange: true
        )
        return applyClipPipeline(
            image: intermediate, srcHeight: canvas.height, layer: layer, frame: frame,
            renderSize: renderSize, alpha: alpha, bakeOpacity: bakeOpacity
        )
    }

    /// Blend `image` over `background`, then fade the blend to background by `opacity`.
    private static func blend(_ image: CIImage, over background: CIImage, filter name: String, opacity: Double) -> CIImage {
        // Ensure blend covers entire frame; avoid black borders.
        let blended = image.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: background])
            .composited(over: background)
        guard opacity < 1 else { return blended }
        let f = CIFilter(name: "CIDissolveTransition")
        f?.setValue(background, forKey: kCIInputImageKey)
        f?.setValue(blended, forKey: "inputTargetImage")
        f?.setValue(opacity, forKey: "inputTime")
        return (f?.outputImage ?? blended).cropped(to: background.extent)
    }

    /// Apply adjustment layer effects to the composited image so far.
    private static func applyAdjustmentLayer(
        _ layer: LayerPlan,
        accum: CIImage,
        frame: Int
    ) -> CIImage {
        let clip = layer.clip
        guard let effects = clip.effects, !effects.isEmpty else { return accum }
        var image = accum.unpremultiplyingAlpha()
        let offset = frame - clip.startFrame
        for effect in effects where effect.enabled {
            guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
            image = descriptor.render(image, effect: effect, atOffset: offset)
        }
        return image
    }

    /// Tag output Rec. 709 at the buffer level so downstream reads our bytes correctly.
    private static func tag709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func composedLayer(
        _ layer: LayerPlan,
        buffer: CVPixelBuffer,
        frame: Int,
        renderSize: CGSize,
        bakeOpacity: Bool = true
    ) -> CIImage? {
        let alpha = min(1.0, max(0.0, layer.clip.opacityAt(frame: frame)))
        guard alpha > 0 else { return nil }

        // Undo premultiplied alpha to avoid dark edges.
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            .unpremultiplyingAlpha()
        return applyClipPipeline(
            image: image, srcHeight: CGFloat(CVPixelBufferGetHeight(buffer)), layer: layer,
            frame: frame, renderSize: renderSize, alpha: alpha, bakeOpacity: bakeOpacity
        )
    }

    /// Crop → effects → transform → opacity, sampled from `layer.clip` at `frame`.
    private static func applyClipPipeline(
        image input: CIImage,
        srcHeight: CGFloat,
        layer: LayerPlan,
        frame: Int,
        renderSize: CGSize,
        alpha: Double,
        bakeOpacity: Bool
    ) -> CIImage? {
        let clip = layer.clip
        var image = input

        let crop = clip.cropAt(frame: frame)
        if !crop.isIdentity {
            // Display-space insets → source pixels → CI's bottom-left origin.
            let avRect = CGRect(
                x: crop.left * layer.natSize.width,
                y: crop.top * layer.natSize.height,
                width: max(1, crop.visibleWidthFraction * layer.natSize.width),
                height: max(1, crop.visibleHeightFraction * layer.natSize.height)
            ).applying(layer.preferredTransform.inverted())
            image = image.cropped(to: CGRect(
                x: avRect.origin.x,
                y: srcHeight - avRect.origin.y - avRect.height,
                width: avRect.width,
                height: avRect.height
            ))
        }

        // Effects apply in source-pixel space: after crop, before placement.
        if let effects = clip.effects, !effects.isEmpty {
            let offset = frame - clip.startFrame
            for effect in effects where effect.enabled {
                guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
                image = descriptor.render(image, effect: effect, atOffset: offset)
            }
        }

        // transformAt drops the flip flags, so use the static transform unless animated.
        let t = clip.hasTransformAnimation ? clip.transformAt(frame: frame) : clip.transform
        let av = layer.preferredTransform.concatenating(
            CompositionBuilder.affineTransform(for: t, natSize: layer.natSize, renderSize: renderSize)
        )
        // Conjugate the AV top-left-origin mapping into CI's bottom-left space.
        let ci = flipY(srcHeight).concatenating(av).concatenating(flipY(renderSize.height))
        image = image.transformed(by: ci)

        if bakeOpacity, alpha < 1 {
            // Fade alpha only; scaling RGB would double-fade
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image
    }

    /// Text renders flat in place; opacity fades apply after. Per-word animation bakes in at raster. Preset only, no keyframed transform.
    private static func composedTextLayer(
        _ layer: LayerPlan,
        frame: Int,
        renderSize: CGSize,
        bakeOpacity: Bool = true
    ) -> CIImage? {
        let clip = layer.clip
        let alpha = min(1.0, max(0.0, clip.opacityAt(frame: frame)))
        guard alpha > 0 else { return nil }
        guard var image = TextFrameRenderer.image(clip: clip, frame: frame, renderSize: renderSize)?
            .unpremultiplyingAlpha() else { return nil }

        if let effects = clip.effects, !effects.isEmpty {
            let offset = frame - clip.startFrame
            for effect in effects where effect.enabled {
                guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
                image = descriptor.render(image, effect: effect, atOffset: offset)
            }
        }

        if bakeOpacity, alpha < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image
    }

    private static func flipY(_ height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}
