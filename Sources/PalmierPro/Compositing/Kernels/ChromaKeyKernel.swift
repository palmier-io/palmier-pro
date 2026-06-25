import CoreImage
import Foundation

/// Chroma key (green/blue screen) via a Metal kernel — qualifies a hue range into a soft alpha
/// matte with spill suppression. Kernel: `Metal/ChromaKey.metal`.
enum ChromaKeyKernel {
    private static let kernel = CIKernelLoader.colorKernel("ChromaKey", "chromaKey")

    static func apply(_ image: CIImage, keyHue: Double, tolerance: Double,
                      softness: Double, spill: Double) -> CIImage {
        guard let kernel, tolerance > 0 else { return image }
        return kernel.apply(extent: image.extent,
                            arguments: [image, Float(keyHue), Float(tolerance),
                                        Float(softness), Float(spill)]) ?? image
    }
}
