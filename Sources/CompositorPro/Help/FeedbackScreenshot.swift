import AppKit
import Foundation

@MainActor
enum FeedbackScreenshot {
    /// Captures the currently visible main app window as PNG data
    static func captureMainWindow() -> Data? {
        let candidate = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !$0.title.hasPrefix("Send feedback") })
        guard let window = candidate, let view = window.contentView else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return downscaledIfNeeded(pngData: png)
    }

    private static let maxDimension: CGFloat = 1920

    private static func downscaledIfNeeded(pngData: Data) -> Data {
        guard let source = NSBitmapImageRep(data: pngData) else { return pngData }
        let width = CGFloat(source.pixelsWide)
        let height = CGFloat(source.pixelsHigh)
        guard width > maxDimension || height > maxDimension else { return pngData }

        let scale = min(maxDimension / width, maxDimension / height)
        let newWidth = Int(width * scale)
        let newHeight = Int(height * scale)

        guard let cgImage = source.cgImage,
              let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) as CGColorSpace?,
              let ctx = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return pngData }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let resized = ctx.makeImage() else { return pngData }
        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(using: .png, properties: [:]) ?? pngData
    }
}
