import AVFoundation
import Testing
@testable import PalmierPro

// Serialized: concurrent Core ML model loads segfault on virtualized CI runners.
@Suite(.serialized)
struct BeatDetectorTests {
    /// 120 BPM click track, accented downbeats every 4 beats — same signal the
    /// Python conversion was validated against.
    private static func writeClickTrack(duration: Double, bpm: Double = 120) throws -> URL {
        let sr = 22050.0
        let n = Int(duration * sr)
        var x = [Float](repeating: 0, count: n)
        let beat = 60.0 / bpm
        var t = 0.0
        var index = 0
        while t < duration {
            let start = Int(t * sr)
            let isDown = index % 4 == 0
            let freq = isDown ? 1500.0 : 1000.0
            let amp: Float = isDown ? 1.0 : 0.6
            for i in 0..<Int(0.05 * sr) where start + i < n {
                let env = Float(exp(-Double(i) / (0.01 * sr)))
                x[start + i] += amp * env * Float(sin(2 * .pi * freq * Double(i) / sr))
            }
            t += beat
            index += 1
        }
        let peak = x.map(abs).max() ?? 1
        x = x.map { $0 / peak * 0.9 }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("beat-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        x.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
        try file.write(from: buffer)
        return url
    }

    @Test func clickTrackBeatsAndBPM() async throws {
        let url = try Self.writeClickTrack(duration: 8)
        defer { try? FileManager.default.removeItem(at: url) }

        let detector = try BeatDetector(computeUnits: .cpuOnly)
        let result = try await detector.detect(in: url)

        // 16 ground-truth beats at 0, 0.5, ... 7.5s; model may add/miss one at the edges.
        #expect(result.beats.count >= 14 && result.beats.count <= 18)
        #expect(abs(result.bpm - 120) < 1)

        // Every ground-truth beat within 40ms (2 frames) of a detection.
        let groundTruth = stride(from: 0.5, through: 7.0, by: 0.5)
        for gt in groundTruth {
            let nearest = result.beats.min(by: { abs($0 - gt) < abs($1 - gt) })!
            #expect(abs(nearest - gt) < 0.04, "beat at \(gt)s detected at \(nearest)s")
        }
    }

    @Test func longerThanOneChunkStitches() async throws {
        // 35s > one 30s chunk — exercises the border-overlap stitcher.
        let url = try Self.writeClickTrack(duration: 35)
        defer { try? FileManager.default.removeItem(at: url) }

        let detector = try BeatDetector(computeUnits: .cpuOnly)
        let result = try await detector.detect(in: url)

        #expect(abs(result.bpm - 120) < 1)
        // ~70 beats; no dropouts at the chunk seam (29-31s region must have beats).
        #expect(result.beats.count >= 66)
        let seam = result.beats.filter { $0 > 28.9 && $0 < 31.1 }
        #expect(seam.count >= 3, "beats missing around chunk seam: \(seam)")
    }
}
