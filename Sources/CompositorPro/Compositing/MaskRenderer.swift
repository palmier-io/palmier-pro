import CoreGraphics
import CoreImage
import Foundation

/// Applies a clip mask through `CIBlendWithMask`. Shapes that CoreGraphics cannot draw exactly
/// (star/heart) use a documented elliptical approximation; filter failures return the unmasked
/// image so a bad mask never blanks a frame.
enum MaskRenderer {
    static func applied(_ image: CIImage, mask: Mask, canvas: CGRect) -> CIImage {
        guard let maskImage = maskImage(mask, canvas: canvas) else { return image }
        let filter = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: image,
            kCIInputMaskImageKey: maskImage,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: canvas),
        ])
        return (filter?.outputImage ?? image).cropped(to: canvas)
    }

    static func maskImage(_ mask: Mask, canvas: CGRect) -> CIImage? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(canvas)
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        let rect = CGRect(
            x: canvas.midX + (mask.centerX - 0.5) * canvas.width - mask.width * canvas.width / 2,
            y: canvas.midY + (mask.centerY - 0.5) * canvas.height - mask.height * canvas.height / 2,
            width: mask.width * canvas.width,
            height: mask.height * canvas.height
        )
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: mask.rotationDegrees * .pi / 180)
        let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        switch mask.shape {
        case .rectangle, .split:
            context.fill(local)
        case .ellipse, .star, .heart:
            context.fillEllipse(in: local)
        case .diamond:
            context.beginPath()
            context.move(to: CGPoint(x: local.midX, y: local.maxY))
            context.addLine(to: CGPoint(x: local.maxX, y: local.midY))
            context.addLine(to: CGPoint(x: local.midX, y: local.minY))
            context.addLine(to: CGPoint(x: local.minX, y: local.midY))
            context.closePath()
            context.fillPath()
        case .cinematicBars:
            let bar = local.height * 0.12
            context.fill(CGRect(x: local.minX, y: local.maxY - bar, width: local.width, height: local.height - bar * 2))
        }
        context.restoreGState()

        guard var output = context.makeImage().map(CIImage.init(cgImage:)) else { return nil }
        if mask.feather > 0 {
            let radius = mask.feather * Double(min(width, height))
            output = output.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: canvas)
        }
        if mask.invert {
            output = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: output])?.outputImage ?? output
        }
        return output.cropped(to: canvas)
    }
}
