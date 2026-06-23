import CoreImage
import Foundation

/// Glow / halation via Metal kernels — replaces `CIBloom`. Isolates highlights (threshold),
/// optionally tints them warm (halation), blurs, and screen-blends back. Kernel: `Metal/Glow.metal`.
enum GlowKernel {
    private static let bright = CIKernelLoader.colorKernel("Glow", "glowBright")
    private static let composite = CIKernelLoader.kernel("Glow", "glowComposite")

    static func apply(_ image: CIImage, extent: CGRect, intensity: Double,
                      radius: Double, threshold: Double, warmth: Double) -> CIImage {
        guard let bright, let composite, intensity > 0 else { return image }
        let hi = bright.apply(extent: extent, arguments: [image, Float(threshold), Float(warmth)]) ?? image
        let blurred = hi.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        return composite.apply(extent: extent, roiCallback: { _, r in r },
                               arguments: [image, blurred, Float(intensity)]) ?? image
    }
}
