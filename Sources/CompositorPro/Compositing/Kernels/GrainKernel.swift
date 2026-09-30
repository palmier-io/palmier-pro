import CoreImage
import Foundation

/// Film grain via a Metal kernel — luma-masked monochromatic noise, animated per frame.
/// Kernel: `Metal/Grain.metal`.
enum GrainKernel {
    private static let kernel = CIKernelLoader.kernel("Grain", "grain")

    static func apply(_ image: CIImage, amount: Double, size: Double, frame: Int) -> CIImage {
        guard let kernel, amount > 0 else { return image }
        return kernel.apply(extent: image.extent, roiCallback: { _, r in r },
                            arguments: [image, Float(amount), Float(size), Float(frame)]) ?? image
    }
}
