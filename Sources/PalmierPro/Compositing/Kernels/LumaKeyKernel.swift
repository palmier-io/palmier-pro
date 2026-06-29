import CoreImage
import Foundation

/// Luma key for removing bright/white backgrounds. Kernel: `Metal/LumaKey.metal`.
enum LumaKeyKernel {
    private static let kernel = CIKernelLoader.colorKernel("LumaKey", "lumaKey")

    static func apply(_ image: CIImage, threshold: Double, softness: Double) -> CIImage {
        guard let kernel, threshold < 1 else { return image }
        return kernel.apply(extent: image.extent,
                            arguments: [image, Float(threshold), Float(softness)]) ?? image
    }
}
