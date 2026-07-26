import AVFoundation
import Foundation

/// Streams an asset's first audio track as decoded PCM buffers via AVAssetReader.
enum AudioTrackReader {
    enum ReadError: Error {
        case noAudioTrack(String)
        case readFailed(String, underlying: NSError? = nil)

        var message: String {
            switch self {
            case .noAudioTrack(let name): "No audio track in \(name)"
            case .readFailed(let reason, _): reason
            }
        }
    }

    /// Whole-range mono Float32 decode at `sampleRate`
    static func readMonoFloats(from url: URL, sampleRate: Double, range: ClosedRange<Double>? = nil) async throws -> [Float] {
        var samples: [Float] = []
        try await read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ], range: range) { buffer in
            guard let data = buffer.floatChannelData else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// Decode `url`'s first audio track with `outputSettings` (and optional `range`),
    /// invoking `onBuffer` for each PCM buffer. Throws `ReadError` on any failure.
    static func read(
        from url: URL,
        outputSettings: [String: Any],
        range: ClosedRange<Double>? = nil,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ReadError.noAudioTrack(url.lastPathComponent)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ReadError.readFailed(error.localizedDescription, underlying: error as NSError)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            throw ReadError.readFailed("Cannot read audio from \(url.lastPathComponent)")
        }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }

        guard reader.startReading() else {
            let error = reader.error
            throw ReadError.readFailed(
                error?.localizedDescription ?? "Reader could not start",
                underlying: error as NSError?
            )
        }

        while let sample = output.copyNextSampleBuffer() {
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else { continue }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            try onBuffer(pcm)
        }

        if reader.status == .failed {
            let error = reader.error
            throw ReadError.readFailed(error?.localizedDescription ?? "Read failed", underlying: error as NSError?)
        }
    }
}
