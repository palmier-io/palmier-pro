import CoreImage
import Foundation

/// Independent black/white-point remap via a Metal kernel
/// Kernel: `Metal/Levels.metal`.
enum LevelsKernel {
    private static let kernel = CIKernelLoader.colorKernel("Levels", "levels")

    static func apply(_ image: CIImage, blacks: Double, whites: Double) -> CIImage {
        guard let kernel, blacks != 0 || whites != 0 else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, Float(blacks), Float(whites)]) ?? image
    }
}
