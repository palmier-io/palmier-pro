import CoreImage
import Foundation

/// Cuts a baked person-mask matte into a clip's alpha via a Metal kernel. Kernel: `Metal/PersonMask.metal`.
enum PersonMaskKernel {
    private static let kernel = CIKernelLoader.colorKernel("PersonMask", "personMask")
    static let maxFeatherRadius: Double = 40

    /// Fails open (returns `image` unchanged) when there's no kernel or no matte track —
    /// e.g. the bake cache was cleared. Feathering softens the matte edge before the cut.
    static func apply(_ image: CIImage, matte: CIImage?, effect: Effect, atOffset offset: Int) -> CIImage {
        guard let kernel, let matte else { return image }
        let invert = (effect.params["invert"]?.resolved(at: offset, default: 0) ?? 0) >= 0.5
        let feather = effect.params["feather"]?.resolved(at: offset, default: 0) ?? 0

        var softened = matte
        if feather > 0 {
            let radius = feather * Self.maxFeatherRadius
            softened = softened
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: matte.extent)
        }

        return kernel.apply(
            extent: image.extent,
            arguments: [image, softened, invert ? Float(1) : Float(0)]
        ) ?? image
    }
}
