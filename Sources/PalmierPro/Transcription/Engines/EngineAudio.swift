// Shared audio plumbing for the on-device ASR engines: decode any AVFoundation-readable
// file to 16kHz mono Float samples, and pick chunk boundaries at the quietest point
// near a target length so words aren't cut mid-syllable.
import AVFoundation
import Foundation

enum EngineAudio {
    static let sampleRate = 16_000

    enum AudioError: LocalizedError {
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .readFailed(let reason): "Could not read audio for transcription: \(reason)"
            }
        }
    }

    static func loadSamples(fileURL: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: fileURL) } catch {
            throw AudioError.readFailed(error.localizedDescription)
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false
        ) else { throw AudioError.readFailed("bad target format") }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw AudioError.readFailed("unsupported source format")
        }
        var samples: [Float] = []
        let inCapacity = AVAudioFrameCount(32_768)
        let ratio = Double(sampleRate) / file.processingFormat.sampleRate
        var drained = false
        while !drained {
            let outCapacity = AVAudioFrameCount(Double(inCapacity) * ratio) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, statusPtr in
                guard let inBuffer = try? AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity),
                      (try? file.read(into: inBuffer)) != nil, inBuffer.frameLength > 0 else {
                    statusPtr.pointee = .endOfStream
                    return nil
                }
                statusPtr.pointee = .haveData
                return inBuffer
            }
            if status == .error { throw AudioError.readFailed(conversionError?.localizedDescription ?? "conversion failed") }
            if let data = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(outBuffer.frameLength)))
            }
            drained = status == .endOfStream
        }
        return samples
    }

    /// End index for a chunk starting at `from` — the quietest 50ms window near the target boundary.
    static func chunkBoundary(samples: [Float], from: Int, targetSeconds: Double, searchSpanSeconds: Double = 2.5) -> Int {
        let target = from + Int(targetSeconds * Double(sampleRate))
        guard target < samples.count else { return samples.count }
        let span = Int(searchSpanSeconds * Double(sampleRate))
        let windowStart = max(from + span, target - span)
        let windowEnd = min(samples.count - 1, target + span)
        guard windowStart < windowEnd else { return target }

        let rmsWindow = sampleRate / 20
        var best = target
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = windowStart
        while index + rmsWindow < windowEnd {
            var energy: Float = 0
            for sample in samples[index..<(index + rmsWindow)] { energy += sample * sample }
            if energy < bestEnergy {
                bestEnergy = energy
                best = index + rmsWindow / 2
            }
            index += rmsWindow / 2
        }
        return best
    }
}
