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

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        try read(asset: asset, output: output, timeRange: timeRange) { buffer, _ in try onBuffer(buffer) }
    }

    static func readMix(
        from asset: AVAsset, audioMix: AVAudioMix, timeRange: CMTimeRange,
        contentRanges: [CMTimeRange]? = nil,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard timeRange.isValid, timeRange.start.isNumeric, timeRange.duration.isNumeric,
              timeRange.start >= .zero, timeRange.duration > .zero, timeRange.end.isNumeric else {
            throw ReadError.readFailed("Invalid mixed audio time range")
        }
        var decodeRange = timeRange
        if let contentRanges {
            guard contentRanges.allSatisfy({
                $0.isValid && $0.start.isNumeric && $0.duration.isNumeric && $0.end.isNumeric
                    && $0.start >= .zero && $0.duration > .zero
            }) else {
                throw ReadError.readFailed("Invalid planned audio content range")
            }
            let intersections = contentRanges.map { $0.intersection(timeRange) }.filter { $0.isValid && $0.duration > .zero }
            let start = intersections.map(\.start).min() ?? timeRange.end
            let end = intersections.map(\.end).max() ?? timeRange.end
            decodeRange = CMTimeRange(start: start, end: end)
        }
        let startFrame = try sampleFrame(decodeRange.start)
        let decodeFrames = try sampleFrame(decodeRange.end) - startFrame
        let leadingFrames = startFrame - (try sampleFrame(timeRange.start))
        let trailingFrames = try sampleFrame(timeRange.end) - sampleFrame(decodeRange.end)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var decodedFormat: AVAudioFormat?
        if leadingFrames > 0 {
            let format = try await silenceFormat(tracks: tracks)
            try streamSilence(frames: leadingFrames, format: format, onBuffer: onBuffer)
            decodedFormat = format
        }
        var totalFramesRead: Int64 = 0
        if decodeFrames > 0 {
            guard !tracks.isEmpty else { throw ReadError.noAudioTrack("timeline") }
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: LoudnessMeter.sampleRate,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: true,
            ])
            output.audioMix = audioMix
            try read(asset: asset, output: output, timeRange: decodeRange) { buffer, time in
                guard abs(try sampleFrame(time) - startFrame - totalFramesRead) <= 1 else {
                    throw ReadError.readFailed("Mixed audio contains an unexpected decode gap")
                }
                let needed = decodeFrames - totalFramesRead
                guard needed > 0 else { return }
                if Int64(buffer.frameLength) > needed {
                    buffer.frameLength = AVAudioFrameCount(needed)
                }
                totalFramesRead += Int64(buffer.frameLength)
                decodedFormat = buffer.format
                try onBuffer(buffer)
            }
            guard abs(totalFramesRead - decodeFrames) <= 1 else {
                throw ReadError.readFailed("Mixed audio did not decode the complete media range")
            }
        }
        guard trailingFrames > 0 else { return }
        let format: AVAudioFormat
        if let decodedFormat {
            format = decodedFormat
        } else {
            format = try await silenceFormat(tracks: tracks)
        }
        try streamSilence(frames: trailingFrames, format: format, onBuffer: onBuffer)
    }

    private static func streamSilence(frames: Int64, format: AVAudioFormat, onBuffer: (AVAudioPCMBuffer) throws -> Void) throws {
        var remaining = frames
        let capacity = AVAudioFrameCount(min(4_096, remaining))
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let data = silence.floatChannelData else {
            throw ReadError.readFailed("Could not allocate silence buffer")
        }
        let channels = Int(format.channelCount)
        for channel in 0..<(format.isInterleaved ? 1 : channels) {
            data[channel].update(repeating: 0, count: Int(capacity) * (format.isInterleaved ? channels : 1))
        }
        while remaining > 0 {
            try Task.checkCancellation()
            silence.frameLength = AVAudioFrameCount(min(Int64(capacity), remaining))
            try onBuffer(silence)
            remaining -= Int64(silence.frameLength)
        }
    }

    private static func sampleFrame(_ time: CMTime) throws -> Int64 {
        let converted = CMTimeConvertScale(time, timescale: 48_000, method: .roundHalfAwayFromZero)
        guard converted.isNumeric, converted.value >= 0, converted.value < Int64.max - 1 else {
            throw ReadError.readFailed("Audio time is outside the supported sample range")
        }
        return converted.value
    }

    private static func silenceFormat(tracks: [AVAssetTrack]) async throws -> AVAudioFormat {
        var native: AVAudioFormat?
        for track in tracks {
            for description in try await track.load(.formatDescriptions) {
                let format = AVAudioFormat(cmAudioFormatDescription: description)
                if format.channelCount > (native?.channelCount ?? 0) { native = format }
            }
        }
        if let layout = native?.channelLayout {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LoudnessMeter.sampleRate,
                                       interleaved: false, channelLayout: layout)
            _ = try LoudnessMeter.channelWeights(for: format)
            return format
        }
        let channels = native?.channelCount ?? 1
        guard channels <= 2, let format = AVAudioFormat(standardFormatWithSampleRate: LoudnessMeter.sampleRate, channels: channels) else {
            throw ReadError.readFailed("Mixed audio has an unsupported channel layout")
        }
        return format
    }

    private static func read(
        asset: AVAsset, output: AVAssetReaderOutput, timeRange: CMTimeRange?,
        onBuffer: (AVAudioPCMBuffer, CMTime) throws -> Void
    ) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ReadError.readFailed(error.localizedDescription, underlying: error as NSError)
        }

        guard reader.canAdd(output) else {
            throw ReadError.readFailed("Cannot read decoded audio")
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
            try onBuffer(pcm, CMSampleBufferGetPresentationTimeStamp(sample))
        }

        try Task.checkCancellation()
        if reader.status == .cancelled { throw CancellationError() }
        if reader.status == .failed {
            let error = reader.error
            throw ReadError.readFailed(error?.localizedDescription ?? "Read failed", underlying: error as NSError?)
        }
    }
}
