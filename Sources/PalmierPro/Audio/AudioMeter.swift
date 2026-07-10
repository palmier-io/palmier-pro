import Accelerate
import AVFoundation
import Foundation
import Observation

struct AudioMeterAnalysis: Sendable, Equatable {
    struct Channel: Sendable, Equatable {
        let peak, rms: Float
    }
    let left, right: Channel
    static let silence = AudioMeterAnalysis(
        left: Channel(peak: 0, rms: 0),
        right: Channel(peak: 0, rms: 0)
    )
}

struct AudioMeterChannelDisplay: Sendable, Equatable {
    let levelDb, peakDb: Float
    let clipped: Bool
}

struct StereoAudioMeterDisplay: Sendable, Equatable {
    let left, right: AudioMeterChannelDisplay
}

struct AudioMeterChannelState: Sendable {
    nonisolated static let floorDb: Float = -60
    nonisolated static let ceilingDb: Float = 0
    nonisolated static let levelDecayDbPerSecond: Float = 24
    nonisolated static let peakDecayDbPerSecond: Float = 18
    nonisolated static let peakHoldSeconds: TimeInterval = 1.5

    private var levelDb = floorDb
    private var levelTime: TimeInterval = 0
    private var peakDb = floorDb
    private var peakHoldUntil: TimeInterval = 0
    private(set) var clipped = false

    mutating func ingest(rms: Float, peak: Float, at time: TimeInterval) {
        let current = display(at: time)
        levelDb = max(Self.decibels(rms), current.levelDb)
        levelTime = time

        let incomingPeak = Self.decibels(peak)
        if incomingPeak >= current.peakDb {
            peakDb = incomingPeak
            peakHoldUntil = time + Self.peakHoldSeconds
        } else if time > peakHoldUntil {
            peakDb = current.peakDb
            peakHoldUntil = time
        }
        clipped = clipped || peak >= 1
    }

    func display(at time: TimeInterval) -> AudioMeterChannelDisplay {
        let levelElapsed = Float(max(0, time - levelTime))
        let peakElapsed = Float(max(0, time - peakHoldUntil))
        return AudioMeterChannelDisplay(
            levelDb: max(Self.floorDb, levelDb - levelElapsed * Self.levelDecayDbPerSecond),
            peakDb: max(Self.floorDb, peakDb - peakElapsed * Self.peakDecayDbPerSecond),
            clipped: clipped
        )
    }

    mutating func resetClipping() { clipped = false }
    nonisolated static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(floorDb, 20 * log10(amplitude)) : floorDb
    }
}

@Observable
@MainActor
final class AudioMeterHub {
    private var left = AudioMeterChannelState()
    private var right = AudioMeterChannelState()

    func ingest(_ analysis: AudioMeterAnalysis, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        left.ingest(rms: analysis.left.rms, peak: analysis.left.peak, at: time)
        right.ingest(rms: analysis.right.rms, peak: analysis.right.peak, at: time)
    }
    func display(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> StereoAudioMeterDisplay {
        StereoAudioMeterDisplay(left: left.display(at: time), right: right.display(at: time))
    }
    func resetClipping() {
        left.resetClipping()
        right.resetClipping()
    }
    func reset() {
        left = AudioMeterChannelState()
        right = AudioMeterChannelState()
    }
}

enum AudioLevelAnalyzer {
    nonisolated static func analyze(left: [Float], right: [Float], range: Range<Int>) -> AudioMeterAnalysis {
        let upper = min(range.upperBound, min(left.count, right.count))
        let lower = max(0, min(range.lowerBound, upper))
        guard lower < upper else { return .silence }
        let leftResult = left.withUnsafeBufferPointer { metrics($0.baseAddress! + lower, count: upper - lower) }
        let rightResult = right.withUnsafeBufferPointer { metrics($0.baseAddress! + lower, count: upper - lower) }
        return AudioMeterAnalysis(left: leftResult, right: rightResult)
    }

    nonisolated static func analyze(_ buffer: AVAudioPCMBuffer) -> AudioMeterAnalysis {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount > 0,
              let channels = buffer.floatChannelData,
              buffer.frameLength > 0
        else { return .silence }
        let count = Int(buffer.frameLength)
        let right = min(1, Int(buffer.format.channelCount) - 1)
        return AudioMeterAnalysis(
            left: metrics(channels[0], count: count),
            right: metrics(channels[right], count: count)
        )
    }

    nonisolated private static func metrics(_ samples: UnsafePointer<Float>, count: Int) -> AudioMeterAnalysis.Channel {
        var peak: Float = 0
        var rms: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        return AudioMeterAnalysis.Channel(peak: peak, rms: rms)
    }
}
