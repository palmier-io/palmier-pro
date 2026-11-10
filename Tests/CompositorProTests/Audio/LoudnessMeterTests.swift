import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("BS.1770 reference measurements")
struct LoudnessMeterTests {
    private func buffer(frames: Int, channels: Int = 1, interleaved: Bool = false,
                        sample: (Int, Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channels), interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            for channel in 0..<channels {
                if interleaved { data[0][frame * channels + channel] = sample(frame, channel) }
                else { data[channel][frame] = sample(frame, channel) }
            }
        }
        return buffer
    }

    private func measurement(_ buffer: AVAudioPCMBuffer) throws -> LoudnessMeasurement {
        var meter = try LoudnessMeter(format: buffer.format)
        try meter.consume(buffer)
        return meter.measurement
    }

    @Test func overlappingBlocksMatchIndependentReference() throws {
        let input = try buffer(frames: 192_000) { frame, _ in
            let amplitude = (frame / 12_000) % 2 == 0 ? 0.3 : 0.02
            return Float(amplitude * sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        let measured = try #require(try measurement(input).integratedLUFS)
        #expect(abs(measured - -16.5) <= 0.1)
    }

    @Test func oneSecondIsEnoughForIntegratedLoudness() throws {
        let input = try buffer(frames: 48_000) { frame, _ in
            Float(0.1 * sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        let result = try measurement(input)
        #expect(result.status == .measured)
        #expect(abs(try #require(result.integratedLUFS) - -23.0) <= 0.1)
    }

    @Test(arguments: [false, true])
    func oppositePhaseStereoIsMeasuredWithoutDownmixing(interleaved: Bool) throws {
        let input = try buffer(frames: 48_000, channels: 2, interleaved: interleaved) { frame, channel in
            Float((channel == 0 ? 0.1 : -0.1) * sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        let result = try measurement(input)
        #expect(abs(try #require(result.integratedLUFS) - -20.0) <= 0.1)
    }

    @Test func oversamplingFindsAnIntersamplePeak() throws {
        let input = try buffer(frames: 48_000) { frame, _ in
            let fade = min(1, Double(frame) / 480, Double(48_000 - frame) / 480)
            return Float(0.8 * fade * sin(2 * .pi * 12_000 * Double(frame) / 48_000 + .pi / 4))
        }
        let result = try measurement(input)
        #expect(abs(try #require(result.truePeakDBFS) - -1.9) <= 0.15)
    }

    @Test func shortInputStillReportsItsPeak() throws {
        let input = try buffer(frames: 9_600) { frame, _ in
            Float(0.5 * sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        let result = try measurement(input)
        #expect(result.status == .insufficientDuration)
        #expect(abs(try #require(result.truePeakDBFS) - -6.02) <= 0.1)
    }
}
