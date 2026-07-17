import Accelerate
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
        let hopSize = max(1, Int((sampleRate * hopSeconds).rounded()))
        var samples: [Float] = []
        var sumSquares: Float = 0
        var carry = 0

        do {
            try await AudioTrackReader.read(from: url, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], range: range) { pcm in
                guard let channel = pcm.floatChannelData else { return }
                let ptr = channel[0]
                let count = Int(pcm.frameLength)
                var i = 0
                while i < count {
                    let take = min(hopSize - carry, count - i)
                    var partial: Float = 0
                    vDSP_svesq(ptr + i, 1, &partial, vDSP_Length(take))
                    sumSquares += partial
                    carry += take
                    i += take
                    if carry == hopSize {
                        samples.append((sumSquares / Float(hopSize)).squareRoot())
                        sumSquares = 0
                        carry = 0
                    }
                }
            }
        } catch let error as AudioTrackReader.ReadError {
            switch error {
            case .noAudioTrack(let name): throw AudioEnvelopeError.noAudioTrack(name)
            case .readFailed(let reason, _): throw AudioEnvelopeError.readFailed(reason)
            }
        }

        if carry > 0 {
            samples.append((sumSquares / Float(carry)).squareRoot())
        }
        return AudioEnvelope(hopSeconds: hopSeconds, samples: samples)
    }
}
