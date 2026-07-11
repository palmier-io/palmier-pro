import AVFoundation

@MainActor
final class ScrubAudioEngine {
    private enum Direction: Sendable {
        case forward
        case reverse
    }

    private struct Source: @unchecked Sendable {
        let asset: AVAsset
        let audioMix: AVAudioMix?
        let generation: Int
    }

    private struct Request: Sendable {
        let sample: Int64
        let direction: Direction
    }

    private struct PCMWindow: Sendable {
        let startSample: Int64
        let left: [Float]
        let right: [Float]
        let hasAudioTracks: Bool

        var endSample: Int64 { startSample + Int64(left.count) }
    }

    nonisolated private static let sampleRate = 48_000.0
    nonisolated private static let sampleTimescale: CMTimeScale = 48_000
    nonisolated private static let channelCount: AVAudioChannelCount = 2
    nonisolated private static let cacheFrameCount = 96_000
    nonisolated private static let grainFrameCount = 2_400
    nonisolated private static let fadeFrameCount = 144
    nonisolated private static let meterFrameCount = 960
    nonisolated private static let meterPrefetchFrameCount = 12_000

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let meter: AudioMeterHub
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: ScrubAudioEngine.sampleRate,
        channels: ScrubAudioEngine.channelCount,
        interleaved: false
    )!

    private var source: Source?
    private var sourceGeneration = 0
    private var cache: PCMWindow?
    private var latestRequest: Request?
    private var latestMeterSample: Int64?
    private var lastRequestedSample: Int64?
    private var lastDirection: Direction = .forward
    private var decodeTask: Task<Void, Never>?
    private var pendingDecodeRange: Range<Int64>?

    init(meter: AudioMeterHub) {
        self.meter = meter
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func configure(asset: AVAsset?, audioMix: AVAudioMix?, resetMeter: Bool = true) {
        stopScrubbing()
        sourceGeneration &+= 1
        cache = nil
        source = asset.map { Source(asset: $0, audioMix: audioMix, generation: sourceGeneration) }
        if resetMeter { meter.reset() }
        if asset != nil { startEngineIfNeeded() }
    }

    func scrub(to time: CMTime, movingForward: Bool? = nil) {
        guard let source, time.isValid else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let sample = Int64((seconds * Self.sampleRate).rounded())
        guard sample != lastRequestedSample else { return }
        let direction: Direction
        if let movingForward {
            direction = movingForward ? .forward : .reverse
            lastDirection = direction
        } else if let previous = lastRequestedSample {
            direction = sample > previous ? .forward : .reverse
            lastDirection = direction
        } else {
            direction = lastDirection
        }
        lastRequestedSample = sample
        latestMeterSample = nil

        let request = Request(sample: sample, direction: direction)
        latestRequest = request
        if let cache, canServe(sample: sample, from: cache) {
            play(request: request, from: cache)
        } else {
            requestWindow(around: sample, source: source)
        }
    }

    func meterPlayback(at time: CMTime) {
        guard let source, time.isValid else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let sample = Int64((seconds * Self.sampleRate).rounded())
        latestMeterSample = sample
        if let cache, canMeter(sample: sample, from: cache) {
            publishMeter(sample: sample, from: cache)
            if sample + Int64(Self.meterPrefetchFrameCount) >= cache.endSample {
                requestWindow(around: sample, source: source)
            }
        } else {
            requestWindow(around: sample, source: source)
        }
    }

    func stopScrubbing() {
        decodeTask?.cancel()
        decodeTask = nil
        pendingDecodeRange = nil
        latestRequest = nil
        latestMeterSample = nil
        lastRequestedSample = nil
        lastDirection = .forward
        playerNode.stop()
    }

    func teardown() {
        stopScrubbing()
        source = nil
        cache = nil
        engine.stop()
    }

    private func requestWindow(around sample: Int64, source: Source) {
        if let pendingDecodeRange, canServe(sample: sample, from: pendingDecodeRange) { return }

        decodeTask?.cancel()
        let halfWindow = Int64(Self.cacheFrameCount / 2)
        let startSample = max(0, sample - halfWindow)
        let range = startSample..<(startSample + Int64(Self.cacheFrameCount))
        pendingDecodeRange = range

        decodeTask = Task { [weak self] in
            let window = await Self.decodeWindow(
                source: source,
                startSample: startSample,
                frameCount: Self.cacheFrameCount
            )
            guard !Task.isCancelled, let self else { return }
            self.decodeTask = nil
            self.pendingDecodeRange = nil
            guard source.generation == self.source?.generation else { return }
            guard let window else {
                if self.latestRequest != nil { self.lastRequestedSample = nil }
                return
            }
            self.cache = window

            if let request = self.latestRequest {
                if self.canServe(sample: request.sample, from: window) {
                    self.play(request: request, from: window)
                } else {
                    self.requestWindow(around: request.sample, source: source)
                }
                return
            }
            if let meterSample = self.latestMeterSample {
                if self.canMeter(sample: meterSample, from: window) {
                    self.publishMeter(sample: meterSample, from: window)
                } else {
                    self.requestWindow(around: meterSample, source: source)
                }
            }
        }
    }

    private func play(request: Request, from window: PCMWindow) {
        latestRequest = nil
        guard window.hasAudioTracks,
              let buffer = makeGrain(request: request, from: window)
        else {
            meter.ingest(.silence)
            playerNode.stop()
            return
        }

        meter.ingest(AudioLevelAnalyzer.analyze(buffer))
        startEngineIfNeeded()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func canServe(sample: Int64, from window: PCMWindow) -> Bool {
        canServe(sample: sample, from: window.startSample..<window.endSample)
    }

    private func canServe(sample: Int64, from range: Range<Int64>) -> Bool {
        let halfGrain = Int64(Self.grainFrameCount / 2)
        let hasLeftContext = range.lowerBound == 0 || sample - halfGrain >= range.lowerBound
        return range.contains(sample) && hasLeftContext && sample + halfGrain < range.upperBound
    }

    private func canMeter(sample: Int64, from window: PCMWindow) -> Bool {
        sample >= window.startSample
            && sample + Int64(Self.meterFrameCount) <= window.endSample
    }

    private func publishMeter(sample: Int64, from window: PCMWindow) {
        let start = Int(sample - window.startSample)
        let range = start..<(start + Self.meterFrameCount)
        let analysis = window.hasAudioTracks
            ? AudioLevelAnalyzer.analyze(left: window.left, right: window.right, range: range)
            : .silence
        meter.ingest(analysis)
    }

    private func makeGrain(request: Request, from window: PCMWindow) -> AVAudioPCMBuffer? {
        let frameCount = Self.grainFrameCount
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let halfGrain = Int64(frameCount / 2)
        for outputIndex in 0..<frameCount {
            let sourceSample: Int64 = switch request.direction {
            case .forward:
                request.sample - halfGrain + Int64(outputIndex)
            case .reverse:
                request.sample + halfGrain - 1 - Int64(outputIndex)
            }
            let cacheIndex = Int(sourceSample - window.startSample)
            let gain = Self.edgeGain(at: outputIndex, frameCount: frameCount)
            if window.left.indices.contains(cacheIndex) {
                channels[0][outputIndex] = window.left[cacheIndex] * gain
                channels[1][outputIndex] = window.right[cacheIndex] * gain
            } else {
                channels[0][outputIndex] = 0
                channels[1][outputIndex] = 0
            }
        }
        return buffer
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            Log.preview.error("scrub audio engine failed: \(error.localizedDescription)")
        }
    }

    private static func edgeGain(at index: Int, frameCount: Int) -> Float {
        let fadeIn = min(1, Float(index + 1) / Float(fadeFrameCount))
        let fadeOut = min(1, Float(frameCount - index) / Float(fadeFrameCount))
        return min(fadeIn, fadeOut)
    }

    @concurrent
    private static func decodeWindow(
        source: Source,
        startSample: Int64,
        frameCount: Int
    ) async -> PCMWindow? {
        guard let tracks = try? await source.asset.loadTracks(withMediaType: .audio) else { return nil }

        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        guard !tracks.isEmpty else {
            return PCMWindow(startSample: startSample, left: left, right: right, hasAudioTracks: false)
        }

        guard let reader = try? AVAssetReader(asset: source.asset) else { return nil }

        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        output.audioMix = source.audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(value: startSample, timescale: sampleTimescale),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: sampleTimescale)
        )
        guard reader.startReading() else { return nil }

        var runningOffset = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let sampleFormat = AVAudioFormat(streamDescription: streamDescription)
            else { continue }

            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleCount > 0,
                  let pcm = AVAudioPCMBuffer(
                    pcmFormat: sampleFormat,
                    frameCapacity: AVAudioFrameCount(sampleCount)
                  )
            else { continue }
            pcm.frameLength = AVAudioFrameCount(sampleCount)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(sampleCount),
                into: pcm.mutableAudioBufferList
            ) == noErr, let channels = pcm.floatChannelData else { continue }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let destinationOffset: Int
            if presentationTime.isValid {
                let delta = presentationTime - CMTime(value: startSample, timescale: sampleTimescale)
                destinationOffset = Int((delta.seconds * sampleRate).rounded())
            } else {
                destinationOffset = runningOffset
            }

            let sourceChannelCount = Int(sampleFormat.channelCount)
            for sourceIndex in 0..<sampleCount {
                let destinationIndex = destinationOffset + sourceIndex
                guard left.indices.contains(destinationIndex) else { continue }
                left[destinationIndex] = channels[0][sourceIndex]
                right[destinationIndex] = channels[min(1, sourceChannelCount - 1)][sourceIndex]
            }
            runningOffset = max(runningOffset, destinationOffset + sampleCount)
        }

        guard reader.status != .failed else { return nil }
        return PCMWindow(startSample: startSample, left: left, right: right, hasAudioTracks: true)
    }
}
