import CoreImage
import CoreImage.CIFilterBuiltins

/// Pure Core Image colour-grading chain. All slider values are neutral at `0`, so
/// a freshly-defaulted grade is the identity transform.
///
/// Ranges (UI/MCP clamp before calling): temperature/tint/contrast/saturation in
/// −100…100, exposure in −100…100 (mapped to ±2 EV), `lutIntensity` 0…1.
enum ColorGradePipeline {

    /// Basic correction: white balance (temperature/tint) → exposure → contrast/saturation.
    static func basic(
        _ image: CIImage,
        temperature: Double,
        tint: Double,
        exposure: Double,
        contrast: Double,
        saturation: Double
    ) -> CIImage {
        var out = image

        if temperature != 0 || tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = out
            f.neutral = CIVector(x: 6500, y: 0)
            // Warmer as temperature rises; tint shifts green↔magenta.
            f.targetNeutral = CIVector(x: 6500 + temperature * 28.5, y: tint * 1.5)
            out = f.outputImage ?? out
        }

        if exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = out
            f.ev = Float(exposure / 50.0) // ±100 → ±2 EV
            out = f.outputImage ?? out
        }

        if contrast != 0 || saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.contrast = Float(1 + contrast / 100.0)     // 0…2
            f.saturation = Float(1 + saturation / 100.0)  // 0…2
            f.brightness = 0
            out = f.outputImage ?? out
        }

        return out
    }

    /// Apply a LUT, cross-dissolved with the source by `intensity` (0 = source, 1 = full LUT).
    static func lut(_ image: CIImage, cube: CubeLUT, intensity: Double) -> CIImage {
        let f = CIFilter.colorCube()
        f.inputImage = image
        f.cubeDimension = Float(cube.size)
        f.cubeData = cube.cubeData
        guard let full = f.outputImage else { return image }

        let t = min(1, max(0, intensity))
        if t >= 1 { return full }
        if t <= 0 { return image }

        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = full
        mix.time = Float(t)
        return (mix.outputImage ?? full).cropped(to: image.extent)
    }
}
