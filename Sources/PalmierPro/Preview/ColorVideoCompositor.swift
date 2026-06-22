import AVFoundation
import CoreImage

/// Custom `AVVideoCompositing` that renders timelines containing colour grades or
/// chroma keys. Used only when those features are present (`CompositionBuilder`
/// keeps the built-in compositor otherwise), so existing projects are unaffected.
final class ColorVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    private let ciContext: CIContext = {
        let device = MTLCreateSystemDefaultDevice()
        if let device {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private let renderQueue = DispatchQueue(label: "io.palmier.pro.color-compositor", qos: .userInitiated)
    private let workingColorSpace = CGColorSpaceCreateDeviceRGB()

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            // Never leave a request unfinished — the pipeline would stall.
            guard let self else {
                request.finish(with: CompositorError.deallocated)
                return
            }
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? ColorCompositionInstruction,
                      let dest = request.renderContext.newPixelBuffer() else {
                    request.finish(with: CompositorError.badRequest)
                    return
                }
                let frame = Int((request.compositionTime.seconds * Double(instruction.fps)).rounded())
                let bounds = CGRect(origin: .zero, size: request.renderContext.size)

                // Always render something: a produced frame, or a cleared frame so the
                // output buffer never shows uninitialised/stale pixels.
                let output = instruction.composite(at: frame, request: request)?.cropped(to: bounds)
                    ?? CIImage(color: .clear).cropped(to: bounds)
                self.ciContext.render(output, to: dest, bounds: bounds, colorSpace: self.workingColorSpace)
                request.finish(withComposedVideoFrame: dest)
            }
        }
    }

    enum CompositorError: Error { case badRequest, deallocated }
}
