import CoreImage
import Foundation

enum RoundedCornersKernel {
    private static let kernel = CIKernelLoader.kernel("RoundedCorners", "roundedCorners")

    static func apply(_ image: CIImage, rounding: Double) -> CIImage {
        guard rounding.isFinite, rounding > 0 else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, let kernel else { return image }
        let rect = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
        let value = Float(min(1, rounding))
        return kernel.apply(
            extent: extent,
            roiCallback: { _, region in region },
            arguments: [image, rect, value]
        ) ?? image
    }
}
