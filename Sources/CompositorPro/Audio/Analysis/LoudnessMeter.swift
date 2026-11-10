import AVFoundation
import AudioToolbox

struct LoudnessMeasurement: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case measured, belowGate, insufficientDuration
    }

    let status: Status
    let integratedLUFS: Double?
    let truePeakDBFS: Double?
    let analyzedFrames: Int64
    let sampleRate: Double

    var durationSeconds: Double { Double(analyzedFrames) / sampleRate }
}

struct LoudnessMeter {
    static let sampleRate = 48_000.0
    static let blockFrames = 19_200
    static let hopFrames = 4_800
    static let minimumFrames = blockFrames
    static let absoluteGateDB = -70.0
    static let absoluteGateEnergy = pow(10, (absoluteGateDB + 0.691) / 10)
    static let relativeGateOffsetDB = -10.0

    enum MeasurementError: Error, Equatable {
        case unsupportedFormat
        case unsupportedChannelLayout
        case invalidSample
        case durationOverflow
    }

    private struct Filter {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    private struct Channel {
        let weight: Double
        var peak = TruePeakMeter()
        var shelf = Filter(
            b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
            a1: -1.69065929318241, a2: 0.73248077421585
        )
        var highpass = Filter(b0: 1, b1: -2, b2: 1, a1: -1.99004745483399, a2: 0.99007225036621)

        mutating func energy(_ sample: Float) throws -> Double {
            guard sample.isFinite else { throw MeasurementError.invalidSample }
            peak.consume(Double(sample))
            let filtered = highpass.process(shelf.process(Double(sample)))
            return weight * filtered * filtered
        }
    }

    private struct TruePeakMeter {
        private static let delayCount = 13
        private static let phases: [[(delay: Int, weight: Double)]] = (1..<4).map { phase in
            stride(from: phase, through: 48, by: 4).compactMap { tap in
                let x = Double(tap - 24) * .pi / 4
                let weight = sin(x) / x * 0.5 * (1 - cos(2 * .pi * Double(tap) / 48))
                return abs(weight) > 1e-6 ? (tap / 4, weight) : nil
            }
        }
        private var delay = [Double](repeating: 0, count: delayCount)
        private var index = 0
        private var maximum = 0.0

        mutating func consume(_ sample: Double) {
            delay[index] = sample
            maximum = max(maximum, abs(sample))
            for phase in Self.phases {
                var value = 0.0
                for tap in phase {
                    let position = index - tap.delay
                    value += delay[position < 0 ? position + Self.delayCount : position] * tap.weight
                }
                maximum = max(maximum, abs(value))
            }
            index = index + 1 == Self.delayCount ? 0 : index + 1
        }

        var completedPeak: Double {
            var tail = self
            for _ in 0..<Self.delayCount { tail.consume(0) }
            return tail.maximum
        }
    }

    private var channels: [Channel]
    private var hopEnergy = 0.0
    private var hopFrameCount = 0
    private var windowHops = [Double](repeating: 0, count: 4)
    private var hopIndex = 0
    private var filledHops = 0
    private var frameCount: Int64 = 0
    private var blockEnergies: [Double] = []

    init(format: AVAudioFormat) throws {
        self.channels = try Self.channelWeights(for: format).map { Channel(weight: $0) }
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        try Task.checkCancellation()
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.sampleRate == Self.sampleRate,
              let data = buffer.floatChannelData else { throw MeasurementError.unsupportedFormat }
        if channels.count != Int(buffer.format.channelCount) {
            throw MeasurementError.unsupportedChannelLayout
        }
        let nextCount = frameCount.addingReportingOverflow(Int64(buffer.frameLength))
        guard !nextCount.overflow else { throw MeasurementError.durationOverflow }
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<Int(buffer.frameLength) {
            if frame.isMultiple(of: 1_024) { try Task.checkCancellation() }
            var frameEnergy = 0.0
            for channel in channels.indices {
                let sample = interleaved ? data[0][frame * channels.count + channel] : data[channel][frame]
                frameEnergy += try channels[channel].energy(sample)
            }
            hopEnergy += frameEnergy
            hopFrameCount += 1

            if hopFrameCount == Self.hopFrames {
                windowHops[hopIndex] = hopEnergy
                hopIndex = (hopIndex + 1) % windowHops.count
                filledHops = min(windowHops.count, filledHops + 1)
                if filledHops == windowHops.count {
                    blockEnergies.append(windowHops.reduce(0, +) / Double(Self.blockFrames))
                }
                hopEnergy = 0
                hopFrameCount = 0
            }
        }
        frameCount = nextCount.partialValue
    }

    var measurement: LoudnessMeasurement {
        let peak = channels.reduce(0.0) { max($0, $1.peak.completedPeak) }
        let peakDB = peak > 0 ? 20 * log10(peak) : nil
        func result(_ status: LoudnessMeasurement.Status, lufs: Double? = nil) -> LoudnessMeasurement {
            .init(status: status, integratedLUFS: lufs, truePeakDBFS: peakDB,
                  analyzedFrames: frameCount, sampleRate: Self.sampleRate)
        }
        guard frameCount >= Self.minimumFrames else { return result(.insufficientDuration) }

        let absoluteGate = Self.absoluteGateEnergy
        let aboveAbsolute = blockEnergies.filter { $0 >= absoluteGate }
        guard !aboveAbsolute.isEmpty else { return result(.belowGate) }

        let meanEnergy = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let relativeGate = max(absoluteGate, meanEnergy * pow(10, Self.relativeGateOffsetDB / 10))
        let aboveRelative = aboveAbsolute.filter { $0 >= relativeGate }
        guard !aboveRelative.isEmpty else { return result(.belowGate) }

        let gatedMeanEnergy = aboveRelative.reduce(0, +) / Double(aboveRelative.count)
        let integratedLUFS = -0.691 + 10 * log10(gatedMeanEnergy)
        return result(.measured, lufs: integratedLUFS)
    }

    static func channelWeights(for format: AVAudioFormat) throws -> [Double] {
        let count = Int(format.channelCount)
        guard (1...32).contains(count) else { throw MeasurementError.unsupportedChannelLayout }
        guard let layout = format.channelLayout else {
            guard count <= 2 else { throw MeasurementError.unsupportedChannelLayout }
            return [Double](repeating: 1, count: count)
        }
        let labels = try channelLabels(layout)
        guard labels.count == count else { throw MeasurementError.unsupportedChannelLayout }
        return try labels.map { label in
            switch label {
            case kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                 kAudioChannelLabel_Mono, kAudioChannelLabel_LeftCenter, kAudioChannelLabel_RightCenter:
                return 1
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2:
                return 0
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                 kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                 kAudioChannelLabel_CenterSurround:
                return 1.41
            default:
                throw MeasurementError.unsupportedChannelLayout
            }
        }
    }

    private static func channelLabels(_ layout: AVAudioChannelLayout) throws -> [AudioChannelLabel] {
        let input = layout.layout
        if input.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return try labels(in: input)
        }
        var specifier = UInt32(input.pointee.mChannelLayoutTag)
        var property = kAudioFormatProperty_ChannelLayoutForTag
        if specifier == kAudioChannelLayoutTag_UseChannelBitmap {
            specifier = input.pointee.mChannelBitmap.rawValue
            property = kAudioFormatProperty_ChannelLayoutForBitmap
        }
        var size: UInt32 = 0
        let inputSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFormatGetPropertyInfo(property, inputSize, &specifier, &size) == noErr,
              size >= MemoryLayout<AudioChannelLayout>.size, size <= 4_096 else {
            throw MeasurementError.unsupportedChannelLayout
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        guard AudioFormatGetProperty(property, inputSize, &specifier, &size, storage) == noErr else {
            throw MeasurementError.unsupportedChannelLayout
        }
        return try labels(in: storage.assumingMemoryBound(to: AudioChannelLayout.self))
    }

    private static func labels(in layout: UnsafePointer<AudioChannelLayout>) throws -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard (1...32).contains(count),
              let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else {
            throw MeasurementError.unsupportedChannelLayout
        }
        let descriptions = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return UnsafeBufferPointer(start: descriptions, count: count).map(\.mChannelLabel)
    }
}
