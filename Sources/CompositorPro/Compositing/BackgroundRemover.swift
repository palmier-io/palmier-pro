import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Lifts a subject off its background, on device.
///
/// This is Apple's foreground-instance segmentation, not a matting network: it is good when there
/// is a distinct subject against a reasonably plain background, and it is rough on hair, fur and
/// fine detail. It fails outright when there is no clear subject, and that is reported rather than
/// papered over with a bad cutout.
///
/// No model is downloaded and nothing leaves the machine, which is why this can exist in a build
/// with no backend.
enum BackgroundRemover {
    enum Mode: String, Sendable, CaseIterable {
        /// Any distinct foreground subject. The general case.
        case subject
        /// People only, using a dedicated person model. Usually a cleaner edge on a person.
        case person

        var guidance: String {
            switch self {
            case .subject: "Any distinct foreground subject. The general case."
            case .person: "People only, with a cleaner edge. Refuses when no person is found."
            }
        }
    }

    enum RemoveError: Error, Equatable, CustomStringConvertible {
        case unreadableSource
        case noSubjectFound
        case maskGenerationFailed

        var description: String {
            switch self {
            case .unreadableSource: "The source could not be read as an image."
            case .noSubjectFound:
                "No distinct foreground subject was found. This works when a subject stands out "
                    + "from its background; it cannot invent a subject that is not there. For a "
                    + "flat or green-screen background, chroma key is the reliable tool."
            case .maskGenerationFailed: "The mask could not be generated from this image."
            }
        }
    }

    /// A soft matte: `mask` is the Vision alpha, blurred slightly so the cutout does not read as
    /// a hard sticker edge.
    struct Result: Sendable {
        var image: CGImage
        /// Coverage of the frame the subject occupies, 0...1. Low values mean the subject is small
        /// or the segmentation is doubtful.
        var subjectCoverage: Double
    }

    /// Segments `image` and returns a copy with the background made transparent.
    ///
    /// `feather` is in points at the image's own scale; 0 leaves Vision's own edge untouched.
    static func removeBackground(
        from image: CGImage,
        mode: Mode,
        feather: Double
    ) async throws -> Result {
        let scale = CGFloat(max(image.width, image.height))
        let radius = max(0, feather / 100 * scale)
        let masked: CVPixelBuffer = try await perform(on: image, mode: mode)

        guard let samples = maskSamples(masked) else { throw RemoveError.maskGenerationFailed }
        guard let composed = compose(
            image: image, samples: samples, featherRadius: radius
        ) else {
            throw RemoveError.maskGenerationFailed
        }
        return Result(image: composed, subjectCoverage: coverage(of: samples))
    }

    // MARK: - Vision

    /// Runs the request on a background executor. Vision has no async CGImage entry point in the
    /// Swift overlay, so the synchronous form is used deliberately here — never on the main actor.
    @concurrent
    private static func perform(on image: CGImage, mode: Mode) async throws -> CVPixelBuffer {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        switch mode {
        case .subject:
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let observation = request.results?.first,
                  observation.allInstances.isEmpty == false,
                  let buffer = try? observation.generateScaledMaskForImage(
                      forInstances: observation.allInstances,
                      from: handler
                  )
            else {
                throw RemoveError.noSubjectFound
            }
            return buffer
        case .person:
            let request = VNGeneratePersonSegmentationRequest()
            try handler.perform([request])
            guard let buffer = request.results?.first?.pixelBuffer else {
                throw RemoveError.noSubjectFound
            }
            return buffer
        }
    }

    /// Fraction of the frame the mask marks as subject. Low values mean the subject is small or
    /// the segmentation is doubtful.
    nonisolated static func coverage(of samples: MaskSamples) -> Double {
        guard !samples.values.isEmpty else { return 0 }
        let total = samples.values.reduce(0.0) { $0 + Double($1) }
        return total / Double(samples.values.count * 255)
    }

    // MARK: - Compositing

    /// Applies the mask as the source's alpha. Drawing onto the alpha channel of a premultiplied
    /// context keeps the colour and alpha consistent, which is what a video canvas expects.
    nonisolated static func compose(
        image: CGImage, samples: MaskSamples, featherRadius: CGFloat
    ) -> CGImage? {
        guard samples.width > 0, samples.height > 0 else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        var alpha = [UInt8](repeating: 255, count: width * height)
        for y in 0 ..< height {
            let sampleY = min(samples.height - 1, y * samples.height / height)
            for x in 0 ..< width {
                let sampleX = min(samples.width - 1, x * samples.width / width)
                alpha[y * width + x] = samples.values[sampleY * samples.width + sampleX]
            }
        }
        if featherRadius > 0 {
            alpha = blur(alpha, width: width, height: height, radius: Int(featherRadius.rounded()))
        }
        for index in 0 ..< (width * height) {
            pixels[index * 4 + 3] = alpha[index]
        }
        return context.makeImage()
    }

    /// Reads a Vision mask buffer as plain 8-bit samples. Thin by design: everything below works
    /// on `MaskSamples`, which is what makes the compositing provable without CoreVideo.
    nonisolated static func maskSamples(_ mask: CVPixelBuffer) -> MaskSamples? {
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let format = CVPixelBufferGetPixelFormatType(mask)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        if format == kCVPixelFormatType_OneComponent8 {
            let row = base.assumingMemoryBound(to: UInt8.self)
            values = Array(UnsafeBufferPointer(start: row, count: width * height))
        } else if format == kCVPixelFormatType_OneComponent32Float {
            let row = base.assumingMemoryBound(to: Float.self)
            for index in 0 ..< (width * height) {
                values[index] = UInt8(max(0, min(1, Double(row[index]))) * 255)
            }
        } else {
            return nil
        }
        return MaskSamples(values: values, width: width, height: height)
    }

    struct MaskSamples: Sendable {
        var values: [UInt8]
        var width: Int
        var height: Int
    }

    /// Separable box blur applied three times, which approaches a Gaussian closely enough for an
    /// edge and costs nothing.
    nonisolated static func blur(_ input: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0, width > 0, height > 0 else { return input }
        var current = input
        for _ in 0 ..< 3 {
            current = boxBlurHorizontal(current, width: width, height: height, radius: radius)
            current = boxBlurVertical(current, width: width, height: height, radius: radius)
        }
        return current
    }

    private nonisolated static func boxBlurHorizontal(
        _ input: [UInt8], width: Int, height: Int, radius: Int
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        for y in 0 ..< height {
            var sum = 0
            for offset in -radius ... radius {
                sum += Int(input[y * width + min(width - 1, max(0, offset))])
            }
            for x in 0 ..< width {
                output[y * width + x] = UInt8(sum / (radius * 2 + 1))
                let leaving = input[y * width + min(width - 1, max(0, x - radius))]
                let entering = input[y * width + min(width - 1, x + radius + 1)]
                sum += Int(entering) - Int(leaving)
            }
        }
        return output
    }

    private nonisolated static func boxBlurVertical(
        _ input: [UInt8], width: Int, height: Int, radius: Int
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        for x in 0 ..< width {
            var sum = 0
            for offset in -radius ... radius {
                sum += Int(input[min(height - 1, max(0, offset)) * width + x])
            }
            for y in 0 ..< height {
                output[y * width + x] = UInt8(sum / (radius * 2 + 1))
                let leaving = input[min(height - 1, max(0, y - radius)) * width + x]
                let entering = input[min(height - 1, y + radius + 1) * width + x]
                sum += Int(entering) - Int(leaving)
            }
        }
        return output
    }
}