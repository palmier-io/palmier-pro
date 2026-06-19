import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Custom video-composition instruction carrying everything `ColorVideoCompositor`
/// needs to render a frame: the z-ordered visual layers (top → bottom), per-clip
/// geometry, chroma-key settings, adjustment-layer grades, and pre-baked LUTs.
///
/// Geometry reuses `CompositionBuilder.affineTransform`, the same maths the
/// built-in compositor's layer instructions use, converted into Core Image's
/// bottom-left coordinate space (see `ciTransform`).
final class ColorCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let fps: Int
    let renderSize: CGSize
    /// Top → bottom. The compositor composites bottom-first so index 0 ends up on top.
    let layers: [Layer]
    let luts: [String: CubeLUT]

    struct RenderClip: Sendable {
        let clip: Clip
        let natSize: CGSize
        let preferredTransform: CGAffineTransform
    }

    enum Layer: Sendable {
        /// A full-frame opaque backdrop track (rendered at identity).
        case background(trackID: CMPersistentTrackID)
        /// A timeline video/image track and the clips occupying it.
        case source(trackID: CMPersistentTrackID, clips: [RenderClip])
        /// An adjustment layer that grades everything beneath it for each clip's span.
        case adjustment(clips: [Clip])
    }

    init(
        timeRange: CMTimeRange,
        fps: Int,
        renderSize: CGSize,
        layers: [Layer],
        luts: [String: CubeLUT]
    ) {
        self.timeRange = timeRange
        self.fps = fps
        self.renderSize = renderSize
        self.layers = layers
        self.luts = luts
        var ids: [NSValue] = []
        for layer in layers {
            switch layer {
            case .background(let id), .source(let id, _):
                ids.append(NSNumber(value: id))
            case .adjustment:
                break
            }
        }
        self.requiredSourceTrackIDs = ids.isEmpty ? nil : ids
    }

    // MARK: - Rendering

    func composite(at frame: Int, request: AVAsynchronousVideoCompositionRequest) -> CIImage? {
        var acc: CIImage?
        // Bottom-up so the first (top) layer is composited last.
        for layer in layers.reversed() {
            switch layer {
            case .background(let trackID):
                guard let buffer = request.sourceFrame(byTrackID: trackID) else { continue }
                let img = CIImage(cvPixelBuffer: buffer).cropped(to: CGRect(origin: .zero, size: renderSize))
                acc = compose(img, over: acc)

            case .source(let trackID, let clips):
                guard let rc = activeClip(clips, at: frame),
                      let buffer = request.sourceFrame(byTrackID: trackID) else { continue }
                var img = CIImage(cvPixelBuffer: buffer)
                img = applyChromaKey(img, clip: rc.clip)
                if let grade = rc.clip.colorGrade, grade.hasEffect {
                    img = applyGrade(img, grade) // per-clip grade
                }
                img = applyCrop(img, clip: rc.clip, natSize: rc.natSize,
                                preferredTransform: rc.preferredTransform, frame: frame)
                img = img.transformed(by: ciTransform(rc, frame: frame))
                img = applyOpacity(img, value: rc.clip.opacityAt(frame: frame))
                acc = compose(img, over: acc)

            case .adjustment(let clips):
                guard let base = acc,
                      let clip = clips.first(where: { $0.startFrame <= frame && frame < $0.endFrame }),
                      let grade = clip.colorGrade, grade.hasEffect else { continue }
                acc = applyGrade(base, grade)
            }
        }
        return acc
    }

    private func activeClip(_ clips: [RenderClip], at frame: Int) -> RenderClip? {
        clips.first { $0.clip.startFrame <= frame && frame < $0.clip.endFrame }
    }

    private func compose(_ image: CIImage, over background: CIImage?) -> CIImage {
        guard let background else { return image }
        return image.composited(over: background)
    }

    /// Convert the AVFoundation (top-left, y-down) clip transform into Core Image's
    /// bottom-left, y-up space: flip source vertically → apply AV transform → flip render.
    private func ciTransform(_ rc: RenderClip, frame: Int) -> CGAffineTransform {
        let avTransform = rc.preferredTransform.concatenating(
            CompositionBuilder.affineTransform(for: rc.clip.transformAt(frame: frame),
                                               natSize: rc.natSize, renderSize: renderSize)
        )
        // Flip in the source's natural-size frame (matches the non-rotated common case).
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rc.natSize.height)
        let flipRender = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderSize.height)
        return flipSrc.concatenating(avTransform).concatenating(flipRender)
    }

    private func applyOpacity(_ image: CIImage, value: Double) -> CIImage {
        let o = min(1, max(0, value))
        guard o < 1 else { return image }
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: CGFloat(o), y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: CGFloat(o), z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: CGFloat(o), w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(o))
        return f.outputImage ?? image
    }

    private func applyCrop(_ image: CIImage, clip: Clip, natSize: CGSize,
                           preferredTransform: CGAffineTransform, frame: Int) -> CIImage {
        let crop = clip.cropAt(frame: frame)
        guard !crop.isIdentity else { return image }
        // Crop is in normalized source coords with the top-left origin; image is y-up.
        let h = image.extent.height
        let x = crop.left * image.extent.width
        let w = max(1, crop.visibleWidthFraction * image.extent.width)
        let ch = max(1, crop.visibleHeightFraction * h)
        let y = h - (crop.top * h) - ch
        return image.cropped(to: CGRect(x: image.extent.origin.x + x, y: image.extent.origin.y + y, width: w, height: ch))
    }

    private func applyChromaKey(_ image: CIImage, clip: Clip) -> CIImage {
        guard let key = clip.chromaKey, key.isActive else { return image }
        return ChromaKeyPipeline.apply(
            image,
            keyR: key.keyColor.r, keyG: key.keyColor.g, keyB: key.keyColor.b,
            tolerance: key.tolerance, softness: key.softness, spill: key.spill, edgeFeather: key.edgeFeather
        )
    }

    private func applyGrade(_ image: CIImage, _ grade: ColorGrade) -> CIImage {
        var out = image
        if grade.hasBasicEffect {
            out = ColorGradePipeline.basic(out, temperature: grade.temperature, tint: grade.tint,
                                           exposure: grade.exposure, contrast: grade.contrast, saturation: grade.saturation)
        }
        if grade.hasLUTEffect, let ref = grade.lutRef, let cube = luts[ref] {
            out = ColorGradePipeline.lut(out, cube: cube, intensity: grade.lutIntensity)
        }
        return out.cropped(to: image.extent)
    }
}
