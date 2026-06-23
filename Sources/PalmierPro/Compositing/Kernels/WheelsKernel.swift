import CoreImage
import Foundation

/// Lift/Gamma/Gain color wheels via a per-pixel Metal kernel
/// Kernel: `Metal/Wheels.metal`.
enum WheelsKernel {
    private static let kernel = CIKernelLoader.colorKernel("Wheels", "wheels")

    static func apply(_ image: CIImage, params p: ResolvedEffectParams) -> CIImage {
        guard let kernel, !ColorWheels.isNeutral(p) else { return image }
        let c = ColorWheels.coefficients(for: p)
        func vec(_ v: SIMD3<Float>) -> CIVector { CIVector(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z)) }
        return kernel.apply(extent: image.extent,
                            arguments: [image, vec(c.lift), vec(c.gain), vec(c.invGamma)]) ?? image
    }
}
