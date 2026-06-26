import AVFoundation
import CoreImage
import Metal

/// Core Image compositor shared by preview (AVPlayerItem) and export (AVAssetExportSession).
final class CustomVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    struct RenderError: Error {}

    // Shared across all instances. Color management off so CI keeps source pixels raw.
    static let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: true,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private let queue = DispatchQueue(label: "io.palmier.compositor", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: AVAsynchronousVideoCompositionRequest] = [:]

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        pending[ObjectIdentifier(request)] = request
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.pending.removeValue(forKey: ObjectIdentifier(request)) != nil
            self.lock.unlock()
            guard live else { return }
            Self.process(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        let cancelled = pending.values
        pending.removeAll()
        lock.unlock()
        for request in cancelled { request.finishCancelledRequest() }
    }

    private static func process(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CompositorInstruction else {
            // Foreign instruction (shouldn't happen): pass the first source through.
            if let first = request.sourceTrackIDs.first,
               let buffer = request.sourceFrame(byTrackID: first.int32Value) {
                request.finish(withComposedVideoFrame: buffer)
            } else {
                request.finish(with: RenderError())
            }
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: RenderError())
            return
        }
        FrameRenderer.render(
            instruction: instruction,
            sourceFrame: { request.sourceFrame(byTrackID: $0) },
            compositionTime: request.compositionTime,
            into: output,
            context: ciContext
        )
        request.finish(withComposedVideoFrame: output)
    }
}
