import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MapSceneRenderOutput: Sendable {
    var stage: URL?
    var digest: String
    var imageDigests: [String: String]
    var videoDigest: String
}

struct MapSceneReusableFile: Sendable {
    var url: URL
    var videoDigest: String
}

typealias MapSceneRenderOperation = @Sendable (MapSceneSpec, MapAtlas, [String: URL], [String: MapSceneReusableFile]) async throws -> MapSceneRenderOutput

struct MapSceneRaster: Sendable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixels: Data

    @concurrent func png() async throws -> Data {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw MapSceneError.invalidSpec("Could not prepare the map preview bitmap.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MapSceneError.invalidSpec("Could not encode the map preview.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MapSceneError.invalidSpec("Map preview encoding failed.") }
        return output as Data
    }
}

struct MapSceneRenderResources: Sendable {
    static let reliefKey = "__bundled_relief__"
    var images: [String: Data] = [:]
    var imageDigests: [String: String] = [:]

    static func load(sources: [String: URL], relief: Bool) throws -> Self {
        var urls = sources
        if relief {
            guard let url = BundledResource.url("Maps/earth-relief.jpg") else {
                throw MapSceneError.invalidSpec("The bundled relief map is missing; rebuild the application resources.")
            }
            urls[reliefKey] = url
        }
        guard urls.count <= 17 else { throw MapSceneError.invalidSpec("A map scene supports at most 16 custom images.") }
        var result = Self()
        var total = 0
        for (key, url) in urls.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let count = size.fileSize, count > 0, count <= 64 * 1_024 * 1_024 else {
                throw MapSceneError.invalidSpec("Map images must be regular files smaller than 64 MiB.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            let data: Data
            do {
                var bytes = Data()
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    guard bytes.count + chunk.count <= 64 * 1_024 * 1_024 else {
                        throw MapSceneError.invalidSpec("Map image exceeded its 64 MiB input limit.")
                    }
                    bytes.append(chunk)
                }
                try handle.close()
                data = bytes
            } catch {
                do { try handle.close() }
                catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
                throw error
            }
            total += data.count
            guard total <= 128 * 1_024 * 1_024 else { throw MapSceneError.invalidSpec("Map images exceed the 128 MiB total input limit.") }
            result.images[key] = data
            result.imageDigests[key] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    func digest(for spec: MapSceneSpec) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = Data(try spec.digest.utf8) + (try encoder.encode(imageDigests))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

enum MapSceneRenderer {
    static let version = "native-map-1"
    private static let gate = AsyncSemaphore(value: 1)

    @concurrent static func render(
        _ spec: MapSceneSpec, atlas: MapAtlas, sources: [String: URL] = [:],
        reusable: [String: MapSceneReusableFile] = [:]
    ) async throws -> MapSceneRenderOutput {
        try await gate.wait()
        var staged: URL?
        do {
            try Task.checkCancellation()
            let resources = try MapSceneRenderResources.load(sources: sources, relief: spec.palette.relief && spec.backgroundImage == nil)
            let digest = try resources.digest(for: spec)
            if let existing = reusable[digest], FileManager.default.fileExists(atPath: existing.url.path),
               try fileDigest(existing.url) == existing.videoDigest {
                let current = try MapSceneRenderResources.load(sources: sources, relief: spec.palette.relief && spec.backgroundImage == nil)
                guard current.imageDigests == resources.imageDigests else {
                    throw MapSceneError.invalidSpec("Map image bytes changed while verifying the reusable video; retry with stable image assets.")
                }
                try Task.checkCancellation()
                await gate.signal()
                return .init(stage: nil, digest: digest, imageDigests: resources.imageDigests, videoDigest: existing.videoDigest)
            }
            let canvas = try MapSceneCanvas(spec: spec, atlas: atlas, resources: resources)
            let stage = try await encode(canvas: canvas, spec: spec)
            staged = stage
            let videoDigest = try fileDigest(stage)
            let current = try MapSceneRenderResources.load(sources: sources, relief: spec.palette.relief && spec.backgroundImage == nil)
            guard current.imageDigests == resources.imageDigests else {
                throw MapSceneError.invalidSpec("Map image bytes changed during rendering; retry with stable image assets.")
            }
            try Task.checkCancellation()
            await gate.signal()
            return .init(stage: stage, digest: digest, imageDigests: resources.imageDigests, videoDigest: videoDigest)
        } catch {
            await gate.signal()
            if let staged {
                do { try FileManager.default.removeItem(at: staged) }
                catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
            }
            throw error
        }
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            try handle.close()
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            do { try handle.close() }
            catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
            throw error
        }
    }

    @concurrent static func sample(
        _ spec: MapSceneSpec, atlas: MapAtlas, frame: Int, sources: [String: URL] = [:]
    ) async throws -> MapSceneRaster {
        guard (0..<spec.durationFrames).contains(frame) else { throw MapSceneError.invalidFrame }
        try await gate.wait()
        do {
            let resources = try MapSceneRenderResources.load(sources: sources, relief: spec.palette.relief && spec.backgroundImage == nil)
            let canvas = try MapSceneCanvas(spec: spec, atlas: atlas, resources: resources)
            let context = try context(width: spec.width, height: spec.height)
            try Task.checkCancellation()
            canvas.draw(in: context, frame: frame)
            guard let bytes = context.data else { throw MapSceneError.invalidSpec("Map preview buffer is unavailable.") }
            let raster = MapSceneRaster(width: spec.width, height: spec.height, bytesPerRow: context.bytesPerRow,
                pixels: Data(bytes: bytes, count: context.bytesPerRow * spec.height))
            await gate.signal()
            return raster
        } catch {
            await gate.signal()
            throw error
        }
    }

    private static func context(width: Int, height: Int, buffer: CVPixelBuffer? = nil) throws -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: buffer.flatMap { CVPixelBufferGetBaseAddress($0) }, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: buffer.map { CVPixelBufferGetBytesPerRow($0) } ?? width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw MapSceneError.invalidSpec("Could not allocate the map frame buffer.")
        }
        return context
    }

    @concurrent private static func encode(canvas: sending MapSceneCanvas, spec: MapSceneSpec) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("map-\(UUID().uuidString).mov")
        var writer: AVAssetWriter?
        do {
            let encoder = try AVAssetWriter(outputURL: output, fileType: .mov)
            writer = encoder
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(1_000_000, spec.width * spec.height * 4)],
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
            guard encoder.canAdd(input) else { throw MapSceneError.invalidSpec("The map video encoder rejected these settings.") }
            encoder.add(input)
            guard encoder.startWriting() else { throw encoder.error ?? MapSceneError.invalidSpec("Map video encoding could not start.") }
            encoder.startSession(atSourceTime: .zero)
            guard let pool = adaptor.pixelBufferPool else { throw MapSceneError.invalidSpec("The map encoder did not create a pixel buffer pool.") }
            for frame in 0..<spec.durationFrames {
                try Task.checkCancellation()
                let deadline = ContinuousClock.now + .seconds(15)
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard encoder.status == .writing, ContinuousClock.now < deadline else {
                        throw encoder.error ?? MapSceneError.invalidSpec("Map video encoder stopped accepting frames.")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try autoreleasepool {
                    var pixelBuffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                          let buffer = pixelBuffer else { throw MapSceneError.invalidSpec("Could not allocate an encoder frame.") }
                    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
                        throw MapSceneError.invalidSpec("Could not lock an encoder frame.")
                    }
                    do {
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        let context = try context(width: spec.width, height: spec.height, buffer: buffer)
                        canvas.draw(in: context, frame: frame)
                    }
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(spec.fps))) else {
                        throw encoder.error ?? MapSceneError.invalidSpec("Map video encoder refused frame \(frame).")
                    }
                }
            }
            encoder.endSession(atSourceTime: CMTime(value: Int64(spec.durationFrames), timescale: Int32(spec.fps)))
            input.markAsFinished()
            await encoder.finishWriting()
            try Task.checkCancellation()
            guard encoder.status == .completed else { throw encoder.error ?? MapSceneError.invalidSpec("Map video encoding failed.") }
            return output
        } catch {
            writer?.cancelWriting()
            do {
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            } catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
            throw error
        }
    }
}
