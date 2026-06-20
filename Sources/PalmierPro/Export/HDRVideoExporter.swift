import AVFoundation
import VideoToolbox

/// HEVC Main10 BT.2020 HLG/PQ export via `AVAssetReader` → `AVAssetWriter`, since
/// `AVAssetExportSession` presets can't emit 10-bit HDR.
/// Reader path limitations: text overlays (CoreAnimationTool is export-session only)
/// and SDR `.cube` LUTs are not applied here.
enum HDRVideoExporter {

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

    /// Non-Sendable AV handles crossed explicitly; exporter is sole owner.
    struct Inputs: @unchecked Sendable {
        let composition: AVComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix?
    }

    static func export(
        _ inputs: Inputs,
        renderSize: CGSize,
        fps: Int,
        transfer: Transfer = .hlg,
        to outputURL: URL
    ) async throws {
        let composition = inputs.composition
        let videoComposition = inputs.videoComposition
        let audioMix = inputs.audioMix
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw HDRExportError(reason: "no video tracks") }

        // Re-tag the composition's working space as HDR (the SDR builder hardcodes 709).
        let hdrVC = videoComposition.mutableCopy() as! AVMutableVideoComposition
        hdrVC.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
        hdrVC.colorTransferFunction = transfer == .hlg
            ? AVVideoTransferFunction_ITU_R_2100_HLG
            : AVVideoTransferFunction_SMPTE_ST_2084_PQ
        hdrVC.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks, videoSettings: readerVideoSettings
        )
        videoOutput.videoComposition = hdrVC
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw HDRExportError(reason: "cannot add video output") }
        reader.add(videoOutput)

        // Audio (optional): mix down to PCM for re-encode.
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
            ])
            out.audioMix = audioMix
            if reader.canAdd(out) { reader.add(out); audioOutput = out }
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: videoWriterSettings(size: renderSize, transfer: transfer)
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw HDRExportError(reason: "cannot add video input") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192_000,
            ])
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) { writer.add(aIn); audioInput = aIn }
        }

        guard reader.startReading() else {
            throw HDRExportError(reason: "reader start: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            throw HDRExportError(reason: "writer start: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let videoPump = PumpBox(videoInput, videoOutput)
        let audioPump = (audioInput != nil && audioOutput != nil) ? PumpBox(audioInput!, audioOutput!) : nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(videoPump) }
            if let audioPump { group.addTask { await pump(audioPump) } }
            await group.waitForAll()
        }

        if reader.status == .failed {
            throw HDRExportError(reason: reader.error?.localizedDescription ?? "reader failed")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw HDRExportError(reason: writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    /// `@unchecked Sendable`: each box is driven from one dedicated serial queue.
    private final class PumpBox: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        init(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput) {
            self.input = input
            self.output = output
        }
    }

    /// Drain one reader output into one writer input, honoring back-pressure.
    private static func pump(_ box: PumpBox) async {
        let queue = DispatchQueue(label: "hdr.pump.\(box.input.mediaType.rawValue)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            box.input.requestMediaDataWhenReady(on: queue) {
                while box.input.isReadyForMoreMediaData {
                    guard let sample = box.output.copyNextSampleBuffer() else {
                        box.input.markAsFinished()
                        cont.resume()
                        return
                    }
                    if !box.input.append(sample) {
                        box.input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }
}
