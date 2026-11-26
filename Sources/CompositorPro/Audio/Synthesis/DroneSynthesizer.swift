import AVFoundation
import Foundation

/// Local tonal drone synthesis (tanpura / shruti style) via Karplus-Strong
/// plucked-string voices. Renders on-device — no server, no account, no credits.
enum DroneSynthesizer {
    static let sampleRate = 44_100.0

    enum Scale: String, CaseIterable, Sendable {
        case rast, hijaz, bayati, major, minor, sustain

        /// Semitones the dominant (Pa) sits below the tonic. Nil = tonic only.
        var paOffsetBelow: Int? {
            switch self {
            case .rast, .hijaz, .major, .minor: return 5
            case .bayati: return 7
            case .sustain: return nil
            }
        }
    }

    enum Pattern: String, CaseIterable, Sendable {
        case tanpura, shrut, sustain
    }

    struct Spec: Sendable {
        var tonic: String
        var octave: Int
        var scale: Scale
        var pattern: Pattern
        var duration: Double

        init(tonic: String, octave: Int = 3, scale: Scale = .rast, pattern: Pattern = .tanpura, duration: Double = 30) {
            self.tonic = tonic
            self.octave = octave
            self.scale = scale
            self.pattern = pattern
            self.duration = duration
        }
    }

    struct SeededRNG: Sendable {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 11) / Float(1 << 53) * 2 - 1
        }
    }

    static func semitone(forTonic tonic: String) -> Int? {
        switch tonic.uppercased() {
        case "C": return 0
        case "C#", "DB": return 1
        case "D": return 2
        case "D#", "EB": return 3
        case "E": return 4
        case "F": return 5
        case "F#", "GB": return 6
        case "G": return 7
        case "G#", "AB": return 8
        case "A": return 9
        case "A#", "BB": return 10
        case "B": return 11
        default: return nil
        }
    }

    static func frequency(semitone: Int, octave: Int) -> Double {
        440 * pow(2, Double(semitone - 9 + (octave - 4) * 12) / 12)
    }

    /// Renders stereo Float32 PCM for the spec.
    static func render(spec: Spec, seed: UInt64 = 42) -> (left: [Float], right: [Float]) {
        let frameCount = max(1, Int(spec.duration * sampleRate))
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        guard let tonicSemi = semitone(forTonic: spec.tonic) else { return (left, right) }

        let sa = frequency(semitone: tonicSemi, octave: spec.octave)
        let saLow = frequency(semitone: tonicSemi, octave: spec.octave - 1)
        let tonicTotal = tonicSemi + (spec.octave - 4) * 12
        let pa = spec.scale.paOffsetBelow.map { 440 * pow(2, Double(tonicTotal - $0 - 9) / 12) }

        var rng = SeededRNG(seed: seed)
        for pluck in plucks(spec: spec, sa: sa, saLow: saLow, pa: pa) {
            mixPluck(frequency: pluck.frequency, at: pluck.at, decay: pluck.decay, gain: pluck.gain, into: &left, right: &right, rng: &rng)
        }
        normalizeAndFade(left: &left, right: &right)
        return (left, right)
    }

    /// Renders and writes a 16-bit PCM stereo WAV to a temporary file. Off-main safe.
    @discardableResult
    static func renderWAV(spec: Spec, seed: UInt64 = 42) throws -> URL {
        let (left, right) = render(spec: spec, seed: seed)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = left.count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                buffer.floatChannelData![0].update(from: l.baseAddress!, count: frameCount)
                buffer.floatChannelData![1].update(from: r.baseAddress!, count: frameCount)
            }
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: - Scheduling

    private struct Pluck {
        let frequency: Double
        let at: Double
        let decay: Double
        let gain: Double
    }

    private static func plucks(spec: Spec, sa: Double, saLow: Double, pa: Double?) -> [Pluck] {
        switch spec.pattern {
        case .tanpura:
            var result: [Pluck] = []
            let step = 0.8
            var t = 0.0
            var i = 0
            while t < spec.duration {
                if i % 4 == 0 {
                    if let pa {
                        result.append(Pluck(frequency: pa, at: t, decay: 0.996, gain: 1.0))
                        result.append(Pluck(frequency: saLow, at: t, decay: 0.996, gain: 0.5))
                    } else {
                        result.append(Pluck(frequency: sa, at: t, decay: 0.996, gain: 1.0))
                    }
                } else {
                    result.append(Pluck(frequency: sa, at: t, decay: 0.996, gain: 1.0))
                }
                t += step
                i += 1
            }
            return result
        case .shrut:
            var result: [Pluck] = []
            var t = 0.0
            while t < spec.duration {
                result.append(Pluck(frequency: sa, at: t, decay: 0.998, gain: 1.0))
                result.append(Pluck(frequency: saLow, at: t, decay: 0.998, gain: 0.6))
                if let pa { result.append(Pluck(frequency: pa, at: t, decay: 0.998, gain: 0.8)) }
                t += 3.0
            }
            return result
        case .sustain:
            var result = [
                Pluck(frequency: sa, at: 0, decay: 0.9995, gain: 1.0),
                Pluck(frequency: saLow, at: 0, decay: 0.9995, gain: 0.35),
            ]
            if let pa { result.append(Pluck(frequency: pa, at: 0, decay: 0.9995, gain: 0.7)) }
            return result
        }
    }

    // MARK: - Karplus-Strong

    private static func mixPluck(
        frequency: Double,
        at: Double,
        decay: Double,
        gain: Double,
        into left: inout [Float],
        right: inout [Float],
        rng: inout SeededRNG
    ) {
        let startFrame = Int((at * sampleRate).rounded())
        let remaining = left.count - startFrame
        guard remaining > 0, gain > 0 else { return }
        let voices: [(detune: Double, pan: Double, level: Double)] = [
            (1.0, -0.6, 0.5),
            (1.0015, 0.6, 0.5),
            (0.9985, 0.0, 0.35),
        ]
        for voice in voices {
            let frames = karplusStrong(frequency: frequency * voice.detune, frameCount: remaining, decay: decay, rng: &rng)
            let lGain = Float(gain * voice.level * (0.5 - voice.pan / 2))
            let rGain = Float(gain * voice.level * (0.5 + voice.pan / 2))
            for i in 0..<remaining {
                left[startFrame + i] += frames[i] * lGain
                right[startFrame + i] += frames[i] * rGain
            }
        }
    }

    private static func karplusStrong(frequency: Double, frameCount: Int, decay: Double, rng: inout SeededRNG) -> [Float] {
        let period = max(2, Int((sampleRate / frequency).rounded()))
        var line = [Float](repeating: 0, count: period)
        // Pitched init (sine + harmonics) with a short noise attack: a pure noise
        // burst leaves DC rumble that outrings the note.
        for i in 0..<period {
            let phase = 2 * .pi * Double(i) / Double(period)
            let attack = exp(-3 * Double(i) / Double(period))
            line[i] = Float(sin(phase) + 0.25 * sin(2 * phase) + 0.1 * sin(3 * phase)) * 0.8
                + rng.next() * 0.2 * Float(attack)
        }
        var out = [Float](repeating: 0, count: frameCount)
        var idx = 0
        for i in 0..<frameCount {
            let current = line[idx]
            let next = line[(idx + 1) % period]
            line[idx] = (current + next) * 0.5 * Float(decay)
            out[i] = current
            idx = idx + 1 == period ? 0 : idx + 1
        }
        return out
    }

    // MARK: - Output conditioning

    /// The noise-burst attack leaves DC/low-frequency rumble that rings at the
    /// loop's DC gain; a 70 Hz highpass keeps the bed clean without touching Pa.
    private static func highpass(_ samples: inout [Float], cutoffHz: Double = 70) {
        let rc = 1 / (2 * .pi * cutoffHz)
        let alpha = rc / (rc + 1 / sampleRate)
        var y: Double = 0
        var prevX: Double = 0
        for i in samples.indices {
            let x = Double(samples[i])
            y = alpha * (y + x - prevX)
            prevX = x
            samples[i] = Float(y)
        }
    }

    private static func normalizeAndFade(left: inout [Float], right: inout [Float]) {
        highpass(&left)
        highpass(&right)
        var peak: Float = 0
        for i in left.indices {
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        guard peak > 0, peak.isFinite else { return }
        let scale: Float = 0.7 / peak
        let fadeFrames = min(left.count / 2, Int((0.03 * sampleRate).rounded()))
        for i in left.indices {
            var gain = scale
            if i < fadeFrames { gain *= Float(i) / Float(fadeFrames) }
            if i >= left.count - fadeFrames { gain *= Float(left.count - i) / Float(fadeFrames) }
            left[i] *= gain
            right[i] *= gain
        }
    }
}
