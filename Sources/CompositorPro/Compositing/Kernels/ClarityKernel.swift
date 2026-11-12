import CoreImage
import Foundation

/// Clarity (local-contrast) + Dehaze via a Metal kernel against a mid-radius blur of the frame.
/// Kernel: `Metal/Clarity.metal`.
enum ClarityKernel {
    private static let kernel = CIKernelLoader.kernel("Clarity", "clarityHaze")

    static func apply(_ image: CIImage, extent: CGRect, clarity: Double, dehaze: Double) -> CIImage {
        guard let kernel, clarity != 0 || dehaze != 0, extent.width > 0, extent.height > 0 else { return image }
        let radius = max(extent.width, extent.height) / 40   // low-frequency local-contrast scale
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect },
                            arguments: [image, blurred, Float(clarity), Float(dehaze)]) ?? image
    }
}
