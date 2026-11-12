import CoreImage
import Foundation

/// Luma-masked highlights & shadows via a per-pixel Metal kernel
enum HighlightsShadowsKernel {
    private static let kernel = CIKernelLoader.colorKernel("HighlightsShadows", "highlightsShadows")

    static func apply(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        guard let kernel, highlights != 0 || shadows != 0 else { return image }
        return kernel.apply(extent: image.extent,
                            arguments: [image, Float(highlights), Float(shadows)]) ?? image
    }
}
