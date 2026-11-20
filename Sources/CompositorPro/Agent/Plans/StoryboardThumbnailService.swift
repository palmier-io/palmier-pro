import CoreGraphics
import Foundation

enum StoryboardThumbnailService {
    @concurrent
    static func load(url: URL, type: ClipType, sourceSeconds: Double) async throws -> CGImage {
        try Task.checkCancellation()
        if type == .image {
            guard let image = ImageEncoder.thumbnail(url: url, maxPixelSize: 480) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try Task.checkCancellation()
            return image
        }
        guard type == .video else { throw FrameCaptureRenderer.RenderError.noVideoTrack }
        let frame = try await FrameCaptureRenderer.media(url: url, sourceSeconds: sourceSeconds)
        defer { try? FileManager.default.removeItem(at: frame.stagedURL) }
        try Task.checkCancellation()
        guard let image = frame.thumbnail else { throw FrameCaptureRenderer.RenderError.noVideoTrack }
        let scale = min(1, 480 / Double(max(image.width, image.height)))
        return ThumbnailRenderer.scale(image, to: CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
    }
}
