import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders the canvas background behind timeline content. `none` keeps the existing transparent
/// result; a missing blur filter falls back to a solid color.
enum CanvasBackgroundRenderer {
    static func image(for background: CanvasBackground, canvas: CGRect, content: CIImage? = nil) -> CIImage? {
        switch background {
        case .none:
            return nil
        case .solid(let color):
            return CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a))
                .cropped(to: canvas)
        case .gradient(let start, let end):
            let filter = CIFilter.linearGradient()
            filter.point0 = CGPoint(x: canvas.midX, y: canvas.maxY)
            filter.point1 = CGPoint(x: canvas.midX, y: canvas.minY)
            filter.color0 = CIColor(red: start.r, green: start.g, blue: start.b, alpha: start.a)
            filter.color1 = CIColor(red: end.r, green: end.g, blue: end.b, alpha: end.a)
            return filter.outputImage?.cropped(to: canvas)
        case .blur(let radius):
            guard let content else {
                return CIImage(color: CIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)).cropped(to: canvas)
            }
            let blurred = content.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0, radius)])
                .cropped(to: canvas)
            // Darken slightly so foreground text keeps contrast over a blurred backdrop.
            return blurred.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.08,
                kCIInputSaturationKey: 1.1,
            ]).cropped(to: canvas)
        }
    }
}
