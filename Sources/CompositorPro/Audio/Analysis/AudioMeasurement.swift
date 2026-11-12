import AVFoundation

struct AudioMeasurement: Codable, Sendable, Equatable {
    let loudness: LoudnessMeasurement
    let samplePeakDBFS: Double?
    let clippedSamples: Int64
    var rmsDBFS: Double?

    var receipt: [String: Any] {
        ["loudnessStatus": loudness.status.rawValue,
         "integratedLUFS": loudness.integratedLUFS as Any? ?? NSNull(),
         "truePeakDBTP": loudness.truePeakDBFS as Any? ?? NSNull(),
         "samplePeakDBFS": samplePeakDBFS as Any? ?? NSNull(),
          "clippedSamples": clippedSamples, "rmsDBFS": rmsDBFS as Any? ?? NSNull(),
          "analyzedSeconds": loudness.durationSeconds]
    }
}

struct AudioMeasurementAccumulator {
    private var meter: LoudnessMeter?
    private var peak = 0.0
    private var clipped: Int64 = 0
    private var energy = 0.0
    private var samples: Int64 = 0

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        if meter == nil { meter = try LoudnessMeter(format: buffer.format) }
        try meter?.consume(buffer)
        guard let data = buffer.floatChannelData else { throw LoudnessMeter.MeasurementError.unsupportedFormat }
        let channels = Int(buffer.format.channelCount)
        for frame in 0..<Int(buffer.frameLength) {
            if frame.isMultiple(of: 1_024) { try Task.checkCancellation() }
            for channel in 0..<channels {
                let sample = abs(Double(buffer.format.isInterleaved ? data[0][frame * channels + channel] : data[channel][frame]))
                peak = max(peak, sample)
                energy += sample * sample
                samples += 1
                if sample >= 1 { clipped += 1 }
            }
        }
    }

    var measurement: AudioMeasurement {
        .init(loudness: meter?.measurement ?? .init(status: .insufficientDuration, integratedLUFS: nil,
                                                   truePeakDBFS: nil, analyzedFrames: 0, sampleRate: LoudnessMeter.sampleRate),
              samplePeakDBFS: peak > 0 ? 20 * log10(peak) : nil, clippedSamples: clipped,
              rmsDBFS: energy > 0 && samples > 0 ? 10 * log10(energy / Double(samples)) : nil)
    }
}
