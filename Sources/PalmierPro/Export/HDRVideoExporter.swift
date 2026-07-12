import AVFoundation
import CoreImage
import VideoToolbox

/// HEVC Main10 BT.2020 HLG/PQ export; `AVAssetExportSession` presets can't emit 10-bit HDR.
enum HDRVideoExporter {

    static let sdrWorkingSpace = CGColorSpace(name: CGColorSpace.itur_709)
        ?? CGColorSpaceCreateDeviceRGB()

    enum Transfer { case hlg, pq }

    struct HDRExportError: LocalizedError {
        let reason: String
        var errorDescription: String? { "HDR export failed: \(reason)" }
    }

    // MARK: - Encode settings

    static let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    static func colorProperties(_ transfer: Transfer) -> [String: Any] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: transfer == .hlg
                ? AVVideoTransferFunction_ITU_R_2100_HLG
                : AVVideoTransferFunction_SMPTE_ST_2084_PQ,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
    }

    static func videoWriterSettings(size: CGSize, transfer: Transfer) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: colorProperties(transfer),
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main10_AutoLevel,
            ],
        ]
    }

    static var readerVideoSettings: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
    }

    // MARK: - Export

    struct Inputs: @unchecked Sendable {
        let composition: AVComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix?
    }

    static func export(
        _ inputs: Inputs,
        renderSize: CGSize,
        transfer: Transfer = .hlg,
        to outputURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let composition = inputs.composition
        let videoComposition = inputs.videoComposition
        let audioMix = inputs.audioMix
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw HDRExportError(reason: "no video tracks") }
        let totalSeconds = try await composition.load(.duration).seconds

        // Convert 709 → HLG per frame in CoreImage; relabeling the composition as HLG would tag
        // the output HDR without converting pixels, blowing out SDR midtones.
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks, videoSettings: readerVideoSettings
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw HDRExportError(reason: "cannot add video output") }
        reader.add(videoOutput)

        let audioTracks = try await composition.loadTracks(withMediaType: .audio)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: videoWriterSettings(size: renderSize, transfer: transfer)
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw HDRExportError(reason: "cannot add video input") }
        writer.add(videoInput)

        // Add the audio reader output and writer input atomically — an output nobody drains stalls
        // the reader's shared read-ahead and deadlocks the video pump.
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
            ])
            out.audioMix = audioMix
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192_000,
            ])
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(aIn) {
                reader.add(out); writer.add(aIn)
                audioOutput = out; audioInput = aIn
            }
        }

        // The adaptor must be created before the writer starts.
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: attrs
        )
        // Render into the space matching the tagged transfer, or pixels won't agree with metadata.
        let transferName = transfer == .pq ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG
        let outputSpace = CGColorSpace(name: transferName)
            ?? CGColorSpace(name: CGColorSpace.itur_2020) ?? sdrWorkingSpace
        let processing = ProcessingContext(
            input: videoInput, output: videoOutput, reader: reader, adaptor: adaptor,
            ciContext: CIContext(options: [.workingColorSpace: sdrWorkingSpace]),
            renderSize: renderSize, inputSpace: sdrWorkingSpace, outputSpace: outputSpace
        )

        guard reader.startReading() else {
            throw HDRExportError(reason: "reader start: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            throw HDRExportError(reason: "writer start: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let progressReporter: (@Sendable (Double) -> Void)?
        if let onProgress, totalSeconds > 0 {
            progressReporter = { secs in onProgress(min(1, max(0, secs / totalSeconds))) }
        } else {
            progressReporter = nil
        }
        let failure = FailureBox()
        let audioPump = (audioInput != nil && audioOutput != nil) ? PumpBox(audioInput!, audioOutput!, reader) : nil
        nonisolated(unsafe) let unsafeReader = reader
        nonisolated(unsafe) let unsafeWriter = writer
        try await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pumpVideoProcessed(processing, failure: failure, onSeconds: progressReporter) }
                if let audioPump { group.addTask { await pump(audioPump, failure: failure) } }
                await group.waitForAll()
            }
            try Task.checkCancellation()
        } onCancel: {
            unsafeReader.cancelReading()
            unsafeWriter.cancelWriting()
        }

        if let reason = failure.reason {
            reader.cancelReading()
            writer.cancelWriting()
            throw HDRExportError(reason: reason)
        }
        if reader.status == .failed {
            throw HDRExportError(reason: reader.error?.localizedDescription ?? "reader failed")
        }
        try Task.checkCancellation()
        await writer.finishWriting()
        if writer.status != .completed {
            throw HDRExportError(reason: writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    /// Records the first pump failure so the caller errors instead of finalizing a truncated file.
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ reason: String) {
            lock.lock(); defer { lock.unlock() }
            if stored == nil { stored = reason }
        }
        var reason: String? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    /// Each box is driven from one dedicated serial queue.
    private final class PumpBox: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        let reader: AVAssetReader
        init(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, _ reader: AVAssetReader) {
            self.input = input
            self.output = output
            self.reader = reader
        }
    }

    /// Drain one reader output into one writer input, honoring back-pressure.
    private static func pump(_ box: PumpBox, failure: FailureBox, onSeconds: (@Sendable (Double) -> Void)? = nil) async {
        let queue = DispatchQueue(label: "hdr.pump.\(box.input.mediaType.rawValue)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var lastReported = -1.0
            box.input.requestMediaDataWhenReady(on: queue) {
                while box.input.isReadyForMoreMediaData {
                    guard let sample = box.output.copyNextSampleBuffer() else {
                        box.input.markAsFinished()
                        cont.resume()
                        return
                    }
                    if !box.input.append(sample) {
                        // Cancel the shared reader so the other pump's undrained output unblocks.
                        failure.set("audio append failed")
                        box.reader.cancelReading()
                        box.input.markAsFinished()
                        cont.resume()
                        return
                    }
                    if let onSeconds {
                        let secs = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if secs.isFinite, secs - lastReported >= 0.25 { lastReported = secs; onSeconds(secs) }
                    }
                }
            }
        }
    }

    /// Non-Sendable CoreImage handles for the 709 → HLG video pump.
    private struct ProcessingContext: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        let reader: AVAssetReader
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let ciContext: CIContext
        let renderSize: CGSize
        let inputSpace: CGColorSpace
        let outputSpace: CGColorSpace
    }

    /// Like `pump`, but converts each SDR 709 frame to a 10-bit HLG buffer via the adaptor.
    private static func pumpVideoProcessed(
        _ c: ProcessingContext, failure: FailureBox, onSeconds: (@Sendable (Double) -> Void)? = nil
    ) async {
        let queue = DispatchQueue(label: "hdr.pump.video.processed")
        let bounds = CGRect(origin: .zero, size: c.renderSize)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var lastReported = -1.0
            c.input.requestMediaDataWhenReady(on: queue) {
                while c.input.isReadyForMoreMediaData {
                    guard let sample = c.output.copyNextSampleBuffer(),
                          let srcBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        c.input.markAsFinished()
                        cont.resume()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let image = CIImage(cvPixelBuffer: srcBuffer, options: [.colorSpace: c.inputSpace])
                    guard let pool = c.adaptor.pixelBufferPool else {
                        failure.set("pixel buffer pool unavailable")
                        c.reader.cancelReading(); c.input.markAsFinished(); cont.resume(); return
                    }
                    var outBuffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                    guard let outBuffer else {
                        failure.set("pixel buffer alloc failed (\(status))")
                        c.reader.cancelReading(); c.input.markAsFinished(); cont.resume(); return
                    }
                    c.ciContext.render(image, to: outBuffer, bounds: bounds, colorSpace: c.outputSpace)
                    if !c.adaptor.append(outBuffer, withPresentationTime: pts) {
                        failure.set("frame append failed")
                        c.reader.cancelReading(); c.input.markAsFinished(); cont.resume(); return
                    }
                    if let onSeconds {
                        let secs = pts.seconds
                        if secs.isFinite, secs - lastReported >= 0.25 { lastReported = secs; onSeconds(secs) }
                    }
                }
            }
        }
    }
}
