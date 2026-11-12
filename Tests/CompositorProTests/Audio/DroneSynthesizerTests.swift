import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite(.serialized)
struct DroneSynthesizerTests {
    private func energy(at frequency: Double, in samples: [Float], sampleRate: Double) -> Double {
        let k = Int(0.5 + Double(samples.count) * frequency / sampleRate)
        let w = 2 * .pi * Double(k) / Double(samples.count)
        let coeff = 2 * cos(w)
        var s1 = 0.0
        var s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coeff * s1 * s2
    }

    @Test func rendersExpectedDurationAndLevel() {
        let (left, right) = DroneSynthesizer.render(spec: DroneSynthesizer.Spec(tonic: "C", duration: 2))
        #expect(left.count == Int(2 * 44_100))
        let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        #expect(peak > 0.3 && peak <= 0.71)
    }

    @Test func fundamentalMatchesTonic() {
        let (left, _) = DroneSynthesizer.render(
            spec: DroneSynthesizer.Spec(tonic: "A", octave: 3, scale: .sustain, pattern: .sustain, duration: 3)
        )
        let fundamental = energy(at: 220.0, in: left, sampleRate: 44_100)
        let subharmonic = energy(at: 110.0, in: left, sampleRate: 44_100)
        let octave = energy(at: 440.0, in: left, sampleRate: 44_100)
        #expect(fundamental > subharmonic)
        #expect(fundamental > octave)
    }

    @Test func scalesPlaceDominantOnDifferentNotes() {
        let (rast, _) = DroneSynthesizer.render(
            spec: DroneSynthesizer.Spec(tonic: "C", scale: .rast, pattern: .sustain, duration: 2)
        )
        let (bayati, _) = DroneSynthesizer.render(
            spec: DroneSynthesizer.Spec(tonic: "C", scale: .bayati, pattern: .sustain, duration: 2)
        )
        let rastAtPa = energy(at: 98.0, in: rast, sampleRate: 44_100)
        let rastAtBayatiPa = energy(at: 87.3, in: rast, sampleRate: 44_100)
        let bayatiAtPa = energy(at: 87.3, in: bayati, sampleRate: 44_100)
        let bayatiAtRastPa = energy(at: 98.0, in: bayati, sampleRate: 44_100)
        #expect(rastAtPa > rastAtBayatiPa)
        #expect(bayatiAtPa > bayatiAtRastPa)
    }

    @Test func sameSeedIsDeterministic() {
        let a = DroneSynthesizer.render(spec: DroneSynthesizer.Spec(tonic: "D", duration: 1), seed: 7)
        let b = DroneSynthesizer.render(spec: DroneSynthesizer.Spec(tonic: "D", duration: 1), seed: 7)
        #expect(a.left == b.left)
        #expect(a.right == b.right)
    }

    @Test func renderWAVWritesPlayableStereoFile() async throws {
        let url = try DroneSynthesizer.renderWAV(spec: DroneSynthesizer.Spec(tonic: "C", duration: 1))
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        #expect(tracks[0].timeRange.duration.seconds > 0.9)
    }
}
