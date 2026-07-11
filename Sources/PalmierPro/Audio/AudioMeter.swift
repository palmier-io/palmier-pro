import Accelerate
import AVFoundation
import Foundation
import Observation

struct AudioMeterAnalysis: Sendable, Equatable {
    let leftPeak, rightPeak: Float
    static let silence = AudioMeterAnalysis(leftPeak: 0, rightPeak: 0)
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

    mutating func ingest(peak: Float, at time: TimeInterval) {
        let current = display(at: time)
        let incomingPeak = Self.decibels(peak)
        levelDb = max(incomingPeak, current.levelDb)
        levelTime = time

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
        left.ingest(peak: analysis.leftPeak, at: time)
        right.ingest(peak: analysis.rightPeak, at: time)
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
        let count = upper - lower
        return AudioMeterAnalysis(
            leftPeak: left.withUnsafeBufferPointer { peak($0.baseAddress! + lower, count: count) },
            rightPeak: right.withUnsafeBufferPointer { peak($0.baseAddress! + lower, count: count) }
        )
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
            leftPeak: peak(channels[0], count: count),
            rightPeak: peak(channels[right], count: count)
        )
    }

    nonisolated private static func peak(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_maxmgv(samples, 1, &result, vDSP_Length(count))
        return result
    }
}
