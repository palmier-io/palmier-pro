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
        let timeRange = try range.map { range in
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.lowerBound >= 0, range.upperBound > range.lowerBound else {
                throw ReadError.readFailed("Invalid audio time range")
            }
            return CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }
        try await read(from: url, outputSettings: outputSettings, timeRange: timeRange, onBuffer: onBuffer)
    }

    static func read(
        from url: URL,
        outputSettings: [String: Any],
        timeRange: CMTimeRange?,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws {
        try Task.checkCancellation()
        if let timeRange {
            guard timeRange.isValid, timeRange.start.isNumeric, timeRange.duration.isNumeric,
                  timeRange.start >= .zero, timeRange.duration > .zero, timeRange.end.isNumeric else {
                throw ReadError.readFailed("Invalid audio time range")
            }
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ReadError.noAudioTrack(url.lastPathComponent)
        }
        try Task.checkCancellation()

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ReadError.readFailed(error.localizedDescription, underlying: error as NSError)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            throw ReadError.readFailed("Cannot read audio from \(url.lastPathComponent)")
        }
        reader.add(output)
        if let timeRange { reader.timeRange = timeRange }

        guard reader.startReading() else {
            let error = reader.error
            throw ReadError.readFailed(
                error?.localizedDescription ?? "Reader could not start",
                underlying: error as NSError?
            )
        }
        defer { reader.cancelReading() }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
                throw ReadError.readFailed("Decoded audio has no PCM format")
            }
            let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: nil).map { AVAudioChannelLayout(layout: $0) }
            guard let format = AVAudioFormat(streamDescription: asbd, channelLayout: layout) else {
                throw ReadError.readFailed("Decoded audio has an unsupported channel layout")
            }
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            guard sampleCount > 0 else { continue }
            guard sampleCount <= Int32.max else { throw ReadError.readFailed("Decoded audio buffer is too large") }
            let frames = AVAudioFrameCount(sampleCount)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw ReadError.readFailed("Could not allocate a decoded audio buffer")
            }
            pcm.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            guard status == noErr else { throw ReadError.readFailed("Could not copy decoded PCM audio (\(status))") }
            try onBuffer(pcm)
        }

        try Task.checkCancellation()
        if reader.status == .cancelled { throw CancellationError() }
        if reader.status == .failed {
            let error = reader.error
            throw ReadError.readFailed(error?.localizedDescription ?? "Read failed", underlying: error as NSError?)
        }
    }
}
