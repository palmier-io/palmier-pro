import CoreImage
import Foundation

enum EdgeRoundingKernel {
    private static let kernel = CIKernelLoader.kernel("EdgeRounding", "edgeRounding")

    static func apply(_ image: CIImage, edgeRounding: Double, edgeSoftness: Double) -> CIImage {
        let normalizedRounding = edgeRounding.isFinite ? min(1, max(0, edgeRounding)) : 0
        let normalizedSoftness = edgeSoftness.isFinite ? min(1, max(0, edgeSoftness)) : 0
        guard normalizedRounding > 0 || normalizedSoftness > 0 else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, let kernel else { return image }
        let rect = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
        return kernel.apply(
            extent: extent,
            roiCallback: { _, region in region },
            arguments: [image, rect, Float(normalizedRounding), Float(normalizedSoftness)]
        ) ?? image
    }
}
