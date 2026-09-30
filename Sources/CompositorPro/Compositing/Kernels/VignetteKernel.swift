import CoreImage
import Foundation

/// Centered, shaped, feathered vignette via a Metal kernel
/// Kernel: `Metal/Vignette.metal`.
enum VignetteKernel {
    private static let kernel = CIKernelLoader.kernel("Vignette", "vignette")

    static func apply(_ image: CIImage, extent: CGRect, amount: Double,
                      midpoint: Double, roundness: Double, feather: Double) -> CIImage {
        guard let kernel, amount != 0, extent.width > 0, extent.height > 0 else { return image }
        let rect = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
        return kernel.apply(extent: extent, roiCallback: { _, r in r },
                            arguments: [image, rect, Float(amount), Float(midpoint),
                                        Float(roundness), Float(feather)]) ?? image
    }
}
