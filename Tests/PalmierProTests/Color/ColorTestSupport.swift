import CoreImage
import Foundation
@testable import PalmierPro

/// Render a single pixel with colour management disabled so values pass through verbatim.
func renderPixel(_ image: CIImage, at point: CGPoint = .zero) -> (r: Double, g: Double, b: Double, a: Double) {
    let ctx = CIContext(options: [.workingColorSpace: NSNull()])
    var buf = [UInt8](repeating: 0, count: 4)
    let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
    ctx.render(
        image,
        toBitmap: &buf,
        rowBytes: 4,
        bounds: rect,
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return (Double(buf[0]) / 255, Double(buf[1]) / 255, Double(buf[2]) / 255, Double(buf[3]) / 255)
}

func solidImage(r: Double, g: Double, b: Double, a: Double = 1) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
}
