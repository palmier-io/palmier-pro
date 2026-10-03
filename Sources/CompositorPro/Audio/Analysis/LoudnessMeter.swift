import AVFoundation
import AudioToolbox

struct LoudnessMeasurement: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case measured, belowGate, insufficientDuration
    }

    let status: Status
    let integratedLUFS: Double?
    let analyzedFrames: Int64

    var durationSeconds: Double { Double(analyzedFrames) / LoudnessMeter.sampleRate }
}

struct LoudnessMeter {
    static let sampleRate = 48_000.0
    static let hopFrames = 4_800
    static let minimumFrames = 19_200
    static let absoluteGateEnergy = pow(10, (-70.0 + 0.691) / 10)

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

    private let gateEnergy: Double
    private var channels: [Channel] = []
    private var format: AVAudioFormat?
    private var hopEnergy = 0.0
    private var hopFrameCount = 0
    private var hops = [Double](repeating: 0, count: 4)
    private var hopIndex = 0
    private var completedHops = 0
    private var retainedEnergy = 0.0
    private var retainedBlocks: Int64 = 0
    private(set) var frameCount: Int64 = 0

    init(gateEnergy: Double = absoluteGateEnergy) {
        self.gateEnergy = max(Self.absoluteGateEnergy, gateEnergy)
    }

    var relativeGateEnergy: Double? {
        guard retainedBlocks > 0 else { return nil }
        return max(Self.absoluteGateEnergy, retainedEnergy / Double(retainedBlocks) * 0.1)
    }

    var measurement: LoudnessMeasurement {
        if frameCount < Self.minimumFrames {
            return .init(status: .insufficientDuration, integratedLUFS: nil, analyzedFrames: frameCount)
        }
        guard retainedBlocks > 0 else {
            return .init(status: .belowGate, integratedLUFS: nil, analyzedFrames: frameCount)
        }
        return .init(
            status: .measured,
            integratedLUFS: -0.691 + 10 * log10(retainedEnergy / Double(retainedBlocks)),
            analyzedFrames: frameCount
        )
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        try Task.checkCancellation()
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.sampleRate == Self.sampleRate,
              let data = buffer.floatChannelData else { throw MeasurementError.unsupportedFormat }
        if let format {
            guard format.isEqual(buffer.format) else { throw MeasurementError.unsupportedFormat }
        } else {
            channels = try Self.channelWeights(for: buffer.format).map { Channel(weight: $0) }
            format = buffer.format
        }
        let nextCount = frameCount.addingReportingOverflow(Int64(buffer.frameLength))
        guard !nextCount.overflow else { throw MeasurementError.durationOverflow }
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<Int(buffer.frameLength) {
            for channel in channels.indices {
                let sample = interleaved ? data[0][frame * channels.count + channel] : data[channel][frame]
                hopEnergy += try channels[channel].energy(sample)
            }
            hopFrameCount += 1
            if hopFrameCount == Self.hopFrames {
                try Task.checkCancellation()
                hops[hopIndex] = hopEnergy
                hopIndex = (hopIndex + 1) % hops.count
                completedHops = min(hops.count, completedHops + 1)
                if completedHops == hops.count {
                    let energy = hops.reduce(0, +) / Double(Self.minimumFrames)
                    if energy > gateEnergy {
                        retainedEnergy += energy
                        retainedBlocks += 1
                    }
                }
                hopEnergy = 0
                hopFrameCount = 0
            }
        }
        frameCount = nextCount.partialValue
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
        // Both the layout tag and the channel bitmap are UInt32 underneath, and this is
        // handed to AudioFormatGetPropertyInfo as an in-out void pointer, so UInt32 is the
        // honest type for the specifier whichever branch fills it.
        var specifier = UInt32(input.pointee.mChannelLayoutTag)
        var property = kAudioFormatProperty_ChannelLayoutForTag
        if specifier == kAudioChannelLayoutTag_UseChannelBitmap {
            // AudioChannelBitmap is a CF_OPTIONS set, so its storage is only reachable
            // through rawValue rather than by assignment.
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
