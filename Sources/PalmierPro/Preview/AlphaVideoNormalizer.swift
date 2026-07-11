import AVFoundation
import Accelerate
import CoreVideo

// Converts straight-alpha video to premultiplied alpha for correct compositing.
enum AlphaVideoNormalizer {

    /// Returns cached premultiplied-alpha video if source has straight alpha; else nil.
    static func premultipliedVideo(for sourceURL: URL, mediaRef: String) async throws -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              try await trackContainsAlpha(track) else { return nil }

        // Skip rotated/flipped sources since baking orientation would lose the original transform.
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        guard preferredTransform.isIdentity else { return nil }

        let natSize = try await track.load(.naturalSize)
        let size = CGSize(width: abs(natSize.width), height: abs(natSize.height))
        guard size.width >= 2, size.height >= 2 else { return nil }

        let filename = "\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_premul.mov"
        let outputURL = ImageVideoGenerator.cacheDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }

        do {
            return try await transcode(asset: asset, track: track, size: size, to: outputURL)
        } catch {
            Log.preview.error("alpha premultiply failed mediaRef=\(mediaRef): \(error.localizedDescription)")
            return nil
        }
    }

    private static func trackContainsAlpha(_ track: AVAssetTrack) async throws -> Bool {
        guard let format = try await track.load(.formatDescriptions).first else { return false }
        // Only trust the codec's alpha flag, not just format/container capability.
        return CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel
        ) as? Bool ?? false
    }

    private static func transcode(
        asset: AVURLAsset,
        track: AVAssetTrack,
        size: CGSize,
        to outputURL: URL
    ) async throws -> URL {
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else { throw NormalizeError.readerSetupFailed }
        reader.add(readerOutput)

        let fm = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(".writing-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tempURL) }

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
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
        guard writer.canAdd(input) else { throw NormalizeError.writerSetupFailed }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? NormalizeError.readerSetupFailed }
        guard writer.startWriting() else { throw writer.error ?? NormalizeError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "io.palmier.alpha-normalize")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: Result<Void, Error>) {
                let alreadyResumed = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyResumed else { return }
                cont.resume(with: result)
            }
            nonisolated(unsafe) let unsafeReader = reader
            nonisolated(unsafe) let unsafeReaderOutput = readerOutput
            nonisolated(unsafe) let unsafeWriter = writer
            nonisolated(unsafe) let unsafeInput = input
            nonisolated(unsafe) let unsafeAdaptor = adaptor
            unsafeInput.requestMediaDataWhenReady(on: queue) {
                while unsafeInput.isReadyForMoreMediaData {
                    guard let sample = unsafeReaderOutput.copyNextSampleBuffer() else {
                        if unsafeReader.status == .failed {
                            finish(.failure(unsafeReader.error ?? NormalizeError.readFailed))
                        } else {
                            unsafeInput.markAsFinished()
                            finish(.success(()))
                        }
                        return
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    premultiply(pixelBuffer)
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if !unsafeAdaptor.append(pixelBuffer, withPresentationTime: pts) {
                        finish(.failure(unsafeWriter.error ?? NormalizeError.appendFailed))
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NormalizeError.writeFailed }

        guard !fm.fileExists(atPath: outputURL.path) else { return outputURL }
        do {
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            guard fm.fileExists(atPath: outputURL.path) else { throw error }
        }
        return outputURL
    }

    /// In-place premultiply of a 32BGRA buffer: RGB ← RGB·(A/255).
    private static func premultiply(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        var image = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        vImagePremultiplyData_RGBA8888(&image, &image, vImage_Flags(kvImageNoFlags))
    }

    enum NormalizeError: LocalizedError {
        case readerSetupFailed, writerSetupFailed, readFailed, appendFailed, writeFailed
        var errorDescription: String? {
            switch self {
            case .readerSetupFailed: "could not set up reader"
            case .writerSetupFailed: "could not set up writer"
            case .readFailed: "could not read source frames"
            case .appendFailed: "could not append frame"
            case .writeFailed: "could not finish writing"
            }
        }
    }
}
