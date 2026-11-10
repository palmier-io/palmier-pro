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
    static let blockDuration = 0.4 // 400 ms per BS.1770
    static let hopDuration = 0.1 // 100 ms overlap (75% overlap)
    static let blockFrames = Int(sampleRate * blockDuration) // 19200
    static let hopFrames = Int(sampleRate * hopDuration) // 4800
    static let minimumBlocks = 10 // 4 seconds minimum per BS.1770
    static let minimumFrames = minimumBlocks * hopFrames // 192000? No, let's use block-based
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
        var shelf = Filter(
            b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
            a1: -1.69065929318241, a2: 0.73248077421585
        )
        var highpass = Filter(b0: 1, b1: -2, b2: 1, a1: -1.99004745483399, a2: 0.99007225036621)

        mutating func energy(_ sample: Float) throws -> Double {
            guard sample.isFinite else { throw MeasurementError.invalidSample }
            let filtered = highpass.process(shelf.process(Double(sample)))
            return weight * filtered * filtered
        }
    }

    private var channels: [Channel]
    private var blockEnergy = 0.0
    private var blockFrameCount = 0
    private var frameCount: Int64 = 0
    private var blockEnergies: [Double] = []
    private var truePeak: Float = 0

    init(format: AVAudioFormat) throws {
        self.channels = try Self.channelWeights(for: format).map { Channel(weight: $0) }
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        try Task.checkCancellation()
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.sampleRate == Self.sampleRate,
              let data = buffer.floatChannelData else { throw MeasurementError.unsupportedFormat }
        if channels.count != (buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)) {
            throw MeasurementError.unsupportedChannelLayout
        }
        let nextCount = frameCount.addingReportingOverflow(Int64(buffer.frameLength))
        guard !nextCount.overflow else { throw MeasurementError.durationOverflow }
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<Int(buffer.frameLength) {
            var frameEnergy = 0.0
            var framePeak: Float = 0
            for channel in channels.indices {
                let sample = interleaved ? data[0][frame * channels.count + channel] : data[channel][frame]
                frameEnergy += try channels[channel].energy(sample)
                framePeak = max(framePeak, abs(sample))
            }
            blockEnergy += frameEnergy
            blockFrameCount += 1
            truePeak = max(truePeak, framePeak)

            if blockFrameCount == Self.blockFrames {
                if blockEnergy > 0 {
                    blockEnergies.append(blockEnergy / Double(Self.blockFrames))
                }
                blockEnergy = 0
                blockFrameCount = 0
            }
        }
        frameCount = nextCount.partialValue
    }

    var measurement: LoudnessMeasurement {
        let minFramesForMeasurement = Self.blockFrames * Self.minimumBlocks
        if frameCount < minFramesForMeasurement {
            return .init(
                status: .insufficientDuration,
                integratedLUFS: nil,
                truePeakDBFS: nil,
                analyzedFrames: frameCount,
                sampleRate: Self.sampleRate
            )
        }
        guard !blockEnergies.isEmpty else {
            return .init(
                status: .belowGate,
                integratedLUFS: nil,
                truePeakDBFS: truePeak > 0 ? 20 * log10(Double(truePeak)) : nil,
                analyzedFrames: frameCount,
                sampleRate: Self.sampleRate
            )
        }

        let absoluteGate = Self.absoluteGateEnergy
        let aboveAbsolute = blockEnergies.filter { $0 > absoluteGate }
        guard !aboveAbsolute.isEmpty else {
            return .init(
                status: .belowGate,
                integratedLUFS: nil,
                truePeakDBFS: truePeak > 0 ? 20 * log10(Double(truePeak)) : nil,
                analyzedFrames: frameCount,
                sampleRate: Self.sampleRate
            )
        }

        let meanEnergy = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let relativeGate = max(absoluteGate, meanEnergy * pow(10, Self.relativeGateOffsetDB / 10))
        let aboveRelative = aboveAbsolute.filter { $0 > relativeGate }
        guard !aboveRelative.isEmpty else {
            return .init(
                status: .belowGate,
                integratedLUFS: nil,
                truePeakDBFS: truePeak > 0 ? 20 * log10(Double(truePeak)) : nil,
                analyzedFrames: frameCount,
                sampleRate: Self.sampleRate
            )
        }

        let gatedMeanEnergy = aboveRelative.reduce(0, +) / Double(aboveRelative.count)
        let integratedLUFS = -0.691 + 10 * log10(gatedMeanEnergy)
        let truePeakDBFS = truePeak > 0 ? 20 * log10(Double(truePeak)) : nil

        return .init(
            status: .measured,
            integratedLUFS: integratedLUFS.isFinite ? integratedLUFS : nil,
            truePeakDBFS: truePeakDBFS?.isFinite == true ? truePeakDBFS : nil,
            analyzedFrames: frameCount,
            sampleRate: Self.sampleRate
        )
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