import AVFoundation
import Foundation

/// Detects silent (speech-free, low-level) segments in a media asset's audio, on-device,
/// using AVFoundation's asynchronous asset reader — no FFmpeg dependency.
///
/// Mirrors OpenMontage's `tools/video/silence_cutter.py` "mark" capability: it reports
/// where dead air sits so an editor or agent can decide whether to cut it. Ported to
/// CompositorPro's AVFoundation audio stack; no OpenMontage source is copied.
enum SilenceDetector {
    /// Analysis sample rate. Low enough to be fast, high enough for reliable RMS.
    static let sampleRate: Double = 16_000
    /// Width of one analysis cell, in seconds.
    static let cellDuration: Double = 0.05

    /// One detected silent segment, in source-media seconds.
    struct Segment: Sendable, Equatable {
        var startSeconds: Double
        var endSeconds: Double
        var durationSeconds: Double { max(0, endSeconds - startSeconds) }
    }

    /// Detects silent segments in `url`'s first audio track.
    ///
    /// - Parameters:
    ///   - url: Media file on disk.
    ///   - thresholdDb: Audio level below this (dBFS) counts as silence.
    ///   - minSilenceDuration: Segments shorter than this are discarded.
    ///   - paddingSeconds: Seconds of silence to keep on each side of a detected segment,
    ///     clamped to the audio's start/end (prevents clipped speech at edges).
    static func detectSilentSegments(
        in url: URL,
        thresholdDb: Double,
        minSilenceDuration: Double,
        paddingSeconds: Double
    ) async throws -> [Segment] {
        try Task.checkCancellation()
        guard thresholdDb.isFinite, minSilenceDuration > 0, paddingSeconds >= 0 else {
            throw DetectionError.invalidParameters
        }
        let cellSamples = Int(Self.sampleRate * Self.cellDuration)
        guard cellSamples > 0 else { throw DetectionError.invalidParameters }
        let threshold = pow(10, thresholdDb / 20.0) // dBFS → linear amplitude

        var cellFlags: [Bool] = []
        var carry: [Float] = [] // samples not yet forming a full cell

        try await AudioTrackReader.read(
            from: url,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ],
            onBuffer: { buffer in
                try Task.checkCancellation()
                guard let channelData = buffer.floatChannelData else { return }
                let data = channelData[0]
                var samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                if !carry.isEmpty {
                    samples = carry + samples
                    carry.removeAll()
                }
                var offset = 0
                while offset + cellSamples <= samples.count {
                    let end = offset + cellSamples
                    var rms: Double = 0
                    for k in offset..<end { rms += Double(samples[k]) * Double(samples[k]) }
                    let amplitude = sqrt(rms / Double(cellSamples))
                    cellFlags.append(amplitude < threshold)
                    offset = end
                }
                if offset < samples.count {
                    carry = Array(samples[offset...])
                }
            }
        )
        try Task.checkCancellation()
        // Flush any trailing partial cell.
        if !carry.isEmpty {
            var rms: Double = 0
            for s in carry { rms += Double(s) * Double(s) }
            let amplitude = sqrt(rms / Double(carry.count))
            cellFlags.append(amplitude < threshold)
            carry.removeAll()
        }

        guard !cellFlags.isEmpty else { return [] }
        let totalDuration = Double(cellFlags.count) * Self.cellDuration

        // Group consecutive silent cells into raw segments.
        var raw: [Segment] = []
        var i = cellFlags.startIndex
        while i < cellFlags.endIndex {
            guard cellFlags[i] else { i += 1; continue }
            var j = i + 1
            while j < cellFlags.endIndex, cellFlags[j] { j += 1 }
            let start = Double(i) * Self.cellDuration
            let end = Double(j) * Self.cellDuration
            if end - start >= minSilenceDuration {
                raw.append(Segment(startSeconds: start, endSeconds: end))
            }
            i = j
        }
        return merge(pad(raw, totalDuration: totalDuration, padding: paddingSeconds))
    }

    /// Applies padding to each segment, clamped to [0, totalDuration].
    private static func pad(
        _ segments: [Segment], totalDuration: Double, padding: Double
    ) -> [Segment] {
        segments.map { seg in
            Segment(
                startSeconds: max(0, seg.startSeconds - padding),
                endSeconds: min(totalDuration, seg.endSeconds + padding)
            )
        }
    }

    /// Merges segments that overlap after padding.
    private static func merge(_ segments: [Segment]) -> [Segment] {
        guard segments.count > 1 else { return segments }
        var out = [segments[0]]
        for seg in segments.dropFirst() {
            let last = out.removeLast()
            if seg.startSeconds <= last.endSeconds {
                out.append(Segment(startSeconds: last.startSeconds, endSeconds: max(last.endSeconds, seg.endSeconds)))
            } else {
                out.append(last)
                out.append(seg)
            }
        }
        return out
    }

    enum DetectionError: Error, Equatable, Sendable {
        case invalidParameters
        case noAudioTrack
        case readFailed(String)
    }
}
