import AVFoundation
import CoreImage
import VideoToolbox

/// HEVC Main10 BT.2020 HLG/PQ export via `AVAssetReader` → `AVAssetWriter`, since
/// `AVAssetExportSession` presets can't emit 10-bit HDR.
/// Titles are composited per frame here (the CoreAnimationTool is export-session only).
enum HDRVideoExporter {

    /// SDR working space for compositing titles; 709 → HLG maps SDR white to graphics-white.
    static let titleWorkingSpace = CGColorSpace(name: CGColorSpace.itur_709)
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

    /// Non-Sendable AV handles crossed explicitly; exporter is sole owner.
    struct Inputs: @unchecked Sendable {
        let composition: AVComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix?
    }

    /// A title pre-rendered to a canvas-sized image; the pump composites it per frame at the
    /// clip's keyframed opacity, at SDR graphics-white (never HDR peak).
    struct TextOverlay: @unchecked Sendable {
        let clip: Clip
        let image: CIImage
    }

    static func export(
        _ inputs: Inputs,
        renderSize: CGSize,
        fps: Int,
        transfer: Transfer = .hlg,
        to outputURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        textOverlays: [TextOverlay] = []
    ) async throws {
        let composition = inputs.composition
        let videoComposition = inputs.videoComposition
        let audioMix = inputs.audioMix
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw HDRExportError(reason: "no video tracks") }
        let totalSeconds = try await composition.load(.duration).seconds

        // The compositor renders SDR Rec.709; we convert 709 → HLG BT.2020 per frame in CoreImage.
        // Relabeling the composition as HLG (what we used to do) tags the output HDR without
        // converting the pixels, so SDR midtones display at HDR brightness — blown out.
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks, videoSettings: readerVideoSettings
        )
        videoOutput.videoComposition = videoComposition
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

        // Every HDR frame is processed in CoreImage: decode the SDR 709 frame, composite titles,
        // and convert 709 → HLG on output. The adaptor must be created before the writer starts.
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: attrs
        )
        let hlgSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            ?? CGColorSpace(name: CGColorSpace.itur_2020) ?? titleWorkingSpace
        let processing = ProcessingContext(
            input: videoInput, output: videoOutput, adaptor: adaptor,
            ciContext: CIContext(options: [.workingColorSpace: titleWorkingSpace]),
            overlays: textOverlays, fps: fps, renderSize: renderSize,
            inputSpace: titleWorkingSpace, hlgSpace: hlgSpace
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
        let audioPump = (audioInput != nil && audioOutput != nil) ? PumpBox(audioInput!, audioOutput!) : nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pumpVideoProcessed(processing, onSeconds: progressReporter) }
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
    /// `onSeconds` (video pump only) reports each appended sample's PTS in seconds, throttled.
    private static func pump(_ box: PumpBox, onSeconds: (@Sendable (Double) -> Void)? = nil) async {
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

    /// Bundles the non-Sendable CoreImage handles for the title-compositing video pump.
    private struct ProcessingContext: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let ciContext: CIContext
        let overlays: [TextOverlay]
        let fps: Int
        let renderSize: CGSize
        let inputSpace: CGColorSpace
        let hlgSpace: CGColorSpace
    }

    /// Like `pump`, but composites each title over the video frame and writes the result to a
    /// fresh 10-bit HLG buffer via the pixel-buffer adaptor.
    private static func pumpVideoProcessed(
        _ c: ProcessingContext, onSeconds: (@Sendable (Double) -> Void)? = nil
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
                    var image = CIImage(cvPixelBuffer: srcBuffer, options: [.colorSpace: c.inputSpace])
                    let frame = Int((pts.seconds * Double(c.fps)).rounded())
                    for overlay in c.overlays {
                        guard frame >= overlay.clip.startFrame, frame < overlay.clip.endFrame else { continue }
                        let opacity = overlay.clip.opacityAt(frame: frame)
                        guard opacity > 0.001 else { continue }
                        var title = overlay.image
                        if opacity < 0.999 {
                            title = title.applyingFilter("CIColorMatrix", parameters: [
                                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                            ])
                        }
                        image = title.composited(over: image)
                    }
                    guard let pool = c.adaptor.pixelBufferPool else {
                        c.input.markAsFinished(); cont.resume(); return
                    }
                    var outBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                    guard let outBuffer else { continue }
                    c.ciContext.render(image, to: outBuffer, bounds: bounds, colorSpace: c.hlgSpace)
                    if !c.adaptor.append(outBuffer, withPresentationTime: pts) {
                        c.input.markAsFinished(); cont.resume(); return
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
