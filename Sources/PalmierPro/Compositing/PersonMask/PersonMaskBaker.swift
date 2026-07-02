import AVFoundation
import CoreImage
import CoreVideo
import Vision

/// Bakes a person-mask matte video once per clip (grayscale coverage, white = selected person)
/// so `FrameRenderer` can sample it like any other track at playback/export time.
enum PersonMaskBaker {
    static let cache = DiskCache(named: "PersonMasks")

    enum BakerError: LocalizedError {
        case noVideoTrack
        case readerSetupFailed
        case writerSetupFailed
        case writeFailed
        case noPeopleFound

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "Could not read the clip's video track."
            case .readerSetupFailed: "Could not set up the mask bake reader."
            case .writerSetupFailed: "Could not set up the mask bake writer."
            case .writeFailed: "Could not finish writing the mask."
            case .noPeopleFound: "Could not find the selected people in the first frame."
            }
        }
    }

    /// Bakes an alpha-matte video isolating `selectedLabels` across every frame. Reports 0...1
    /// progress on an arbitrary queue.
    static func bake(
        sourceURL: URL,
        mediaRef: String,
        selectedLabels: Set<Int>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BakerError.noVideoTrack
        }
        // Raw sensor orientation, ignoring preferredTransform — matches FrameRenderer, which
        // crops/masks pre-transform and applies preferredTransform once, after, to the image only.
        let natSize = try await track.load(.naturalSize)
        let size = CGSize(width: abs(natSize.width), height: abs(natSize.height))
        guard size.width >= 2, size.height >= 2 else { throw BakerError.noVideoTrack }

        let filename = "\(mediaRef)_\(UUID().uuidString)_personmask.mov"
        let outputURL = cache.directory.appendingPathComponent(filename)

        return try await transcode(
            asset: asset, track: track, size: size,
            selectedLabels: selectedLabels, to: outputURL, progress: progress
        )
    }

    private static func transcode(
        asset: AVURLAsset,
        track: AVAssetTrack,
        size: CGSize,
        selectedLabels: Set<Int>,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else { throw BakerError.readerSetupFailed }
        reader.add(readerOutput)

        let fm = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(".writing-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tempURL) }

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        guard writer.canAdd(input) else { throw BakerError.writerSetupFailed }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? BakerError.readerSetupFailed }
        guard writer.startWriting() else { throw writer.error ?? BakerError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let durationSeconds = max(try await asset.load(.duration).seconds, 0.001)

        var trackers: [PersonMaskTracker] = []
        var seeded = false

        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            let maskImage = try await maskImage(
                for: pixelBuffer, selectedLabels: selectedLabels, trackers: &trackers, seeded: &seeded
            )

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let outBuffer = try? pooledPixelBuffer(from: adaptor) else {
                throw BakerError.writeFailed
            }
            context.render(grayscaleRGB(maskImage, extent: CGRect(origin: .zero, size: size)), to: outBuffer)
            guard adaptor.append(outBuffer, withPresentationTime: pts) else {
                throw writer.error ?? BakerError.writeFailed
            }
            progress(min(1, max(0, pts.seconds / durationSeconds)))
        }
        if reader.status == .failed { throw reader.error ?? BakerError.writeFailed }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? BakerError.writeFailed }

        guard !fm.fileExists(atPath: outputURL.path) else { return outputURL }
        do {
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            guard fm.fileExists(atPath: outputURL.path) else { throw error }
        }
        return outputURL
    }

    /// Resolves the current frame's mask, seeding trackers on frame one and tracking after that.
    private static func maskImage(
        for pixelBuffer: CVPixelBuffer,
        selectedLabels: Set<Int>,
        trackers: inout [PersonMaskTracker],
        seeded: inout Bool
    ) async throws -> CIImage {
        let handler = ImageRequestHandler(pixelBuffer)
        let request = GeneratePersonInstanceMaskRequest()
        guard let observation = try await handler.perform(request) else {
            return CIImage(color: .black).cropped(to: CGRect(
                x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)
            ))
        }

        var resolvedLabels: [Int] = []
        if !seeded {
            resolvedLabels = selectedLabels.filter { observation.allInstances.contains($0) }
            guard !resolvedLabels.isEmpty else { throw BakerError.noPeopleFound }
            trackers = try resolvedLabels.map { try PersonMaskTracker(seedObservation: observation, label: $0) }
            seeded = true
        } else {
            for tracker in trackers {
                if let label = await tracker.resolve(pixelBuffer: pixelBuffer, observation: observation) {
                    resolvedLabels.append(label)
                }
            }
        }

        guard !resolvedLabels.isEmpty else {
            return CIImage(color: .black).cropped(to: CGRect(
                x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)
            ))
        }
        let maskBuffer = try observation.generateScaledMask(for: IndexSet(resolvedLabels), scaledToImageFrom: handler)
        return CIImage(cvPixelBuffer: maskBuffer)
    }

    /// Replicates a mask's red channel into RGB and forces alpha opaque (plain luminance video).
    private static func grayscaleRGB(_ mask: CIImage, extent: CGRect) -> CIImage {
        let scale = CGAffineTransform(
            scaleX: extent.width / max(1, mask.extent.width),
            y: extent.height / max(1, mask.extent.height)
        )
        return mask.transformed(by: scale)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: extent)
    }

    private static func pooledPixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw BakerError.writeFailed }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw BakerError.writeFailed }
        return buffer
    }
}
