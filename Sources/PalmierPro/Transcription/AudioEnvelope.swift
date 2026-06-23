import AVFoundation
import Foundation

struct AudioEnvelope: Sendable, Equatable {
    let hopSeconds: Double
    let samples: [Float]

    var duration: Double { Double(samples.count) * hopSeconds }
}

enum AudioEnvelopeError: LocalizedError {
    case noAudioTrack(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let name): "No audio track in \(name)."
        case .readFailed(let reason): "Could not read audio: \(reason)."
        }
    }
}

enum AudioEnvelopeExtractor {
    static let sampleRate: Double = 16_000
    static let hopSeconds: Double = 0.01

    static func extract(from url: URL, range: ClosedRange<Double>? = nil) async throws -> AudioEnvelope {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioEnvelopeError.noAudioTrack(url.lastPathComponent)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw AudioEnvelopeError.readFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw AudioEnvelopeError.readFailed("Cannot read audio from \(url.lastPathComponent)")
        }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }

        guard reader.startReading() else {
            throw AudioEnvelopeError.readFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        let hopSize = max(1, Int((sampleRate * hopSeconds).rounded()))
        var samples: [Float] = []
        var sumSquares: Float = 0
        var carry = 0

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
            guard let channel = pcm.floatChannelData else { continue }
            let ptr = channel[0]
            let count = Int(frames)
            var i = 0
            while i < count {
                let v = ptr[i]
                sumSquares += v * v
                carry += 1
                if carry == hopSize {
                    samples.append((sumSquares / Float(hopSize)).squareRoot())
                    sumSquares = 0
                    carry = 0
                }
                i += 1
            }
        }

        if reader.status == .failed {
            throw AudioEnvelopeError.readFailed(reader.error?.localizedDescription ?? "Read failed")
        }
        if carry > 0 {
            samples.append((sumSquares / Float(carry)).squareRoot())
        }

        return AudioEnvelope(hopSeconds: hopSeconds, samples: samples)
    }
}
