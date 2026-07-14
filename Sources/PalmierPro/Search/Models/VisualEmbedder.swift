import CoreML
import CoreVideo
import CoreGraphics
import Foundation

final class VisualEmbedder: @unchecked Sendable {
    struct Spec: Codable, Equatable, Sendable {
        let model: String
        let version: Int
        let embeddingDim: Int
        let imageSize: Int
        let contextLength: Int
    }

    let spec: Spec
    private let imageEncoder: MLModel
    private let textEncoder: MLModel
    private let tokenizer: TextTokenizer

    enum ModelError: Error { case badOutput, pixelBufferFailed }

    init(
        imageEncoderURL: URL,
        textEncoderURL: URL,
        tokenizer: TextTokenizer,
        spec: Spec,
        computeUnits: MLComputeUnits = .all
    ) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        imageEncoder = try MLModel(contentsOf: imageEncoderURL, configuration: config)
        textEncoder = try MLModel(contentsOf: textEncoderURL, configuration: config)
        self.tokenizer = tokenizer
        self.spec = spec
    }

    func encode(image: CGImage) throws -> [Float] {
        let buffer = try Self.pixelBuffer(from: image, size: spec.imageSize)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let output = try imageEncoder.prediction(from: input)
        return try Self.vector(from: output, dim: spec.embeddingDim)
    }

    func encode(text: String) throws -> [Float] {
        let tokens = tokenizer.tokenize(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: spec.contextLength)], dataType: .int32)
        for (i, t) in tokens.enumerated() { array[i] = NSNumber(value: t) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: array)])
        let output = try textEncoder.prediction(from: input)
        return try Self.vector(from: output, dim: spec.embeddingDim)
    }

    private static func vector(from output: MLFeatureProvider, dim: Int) throws -> [Float] {
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count == dim else {
            throw ModelError.badOutput
        }
        if array.dataType == .float32 {
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        }
        return (0..<dim).map { array[$0].floatValue }
    }

    private static func pixelBuffer(from image: CGImage, size: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let buffer else { throw ModelError.pixelBufferFailed }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw ModelError.pixelBufferFailed }
        context.interpolationQuality = .high
        // Buffer memory is recycled, not zeroed; alpha sources must blend over black, not garbage.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // SigLIP preprocessing squash-resizes to a square (no aspect crop).
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }
}
