import AppKit
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
        let left: [Int16]
        let right: [Int16]
        let hasAudioTracks: Bool

        var endSample: Int64 { startSample + Int64(left.count) }
    }

    private struct CachedWindow {
        let window: PCMWindow
        var lastUsed: UInt64
    }

    nonisolated private static let sampleRate = 48_000.0
    nonisolated private static let sampleTimescale: CMTimeScale = 48_000
    nonisolated private static let channelCount: AVAudioChannelCount = 2
    nonisolated private static let cacheFrameCount = 96_000
    nonisolated private static let grainFrameCount = 2_400
    nonisolated private static let fadeFrameCount = 144
    nonisolated private static let meterFrameCount = 960
    nonisolated private static let meterPrefetchFrameCount = 12_000
    nonisolated private static let prefetchMarginFrameCount = 24_000
    nonisolated private static let maxCachedWindows = 256
    nonisolated private static let fillBudget = maxCachedWindows - 8
    nonisolated private static let fillStride = cacheFrameCount - grainFrameCount
    nonisolated private static let mixInvalidationDebounce = Duration.milliseconds(250)

    private let meter: AudioMeterHub
    private let output = ScrubAudioOutput(sampleRate: sampleRate)

    private var source: Source?
    private var sourceGeneration = 0
    private var windows: [CachedWindow] = []
    private var useCounter: UInt64 = 0
    private var latestRequest: Request?
    private var latestMeterSample: Int64?
    private var lastRequestedSample: Int64?
    private var lastDirection: Direction = .forward
    private var decodeTask: Task<Void, Never>?
    private var pendingDecodeRange: Range<Int64>?
    private var mixInvalidationTask: Task<Void, Never>?
    private var fillTask: Task<Void, Never>?
    private var lifecycleObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(meter: AudioMeterHub) {
        self.meter = meter
        observeLifecycle()
    }

    isolated deinit {
        removeLifecycleObservers()
        output.invalidate()
    }

    func configure(asset: AVAsset?, audioMix: AVAudioMix?, resetMeter: Bool = true) {
        let mixOnlyChange = asset != nil && asset === source?.asset
        stopScrubbing()
        fillTask?.cancel()
        fillTask = nil
        sourceGeneration &+= 1
        source = asset.map { Source(asset: $0, audioMix: audioMix, generation: sourceGeneration) }
        if mixOnlyChange {
            scheduleMixInvalidation()
        } else {
            mixInvalidationTask?.cancel()
            mixInvalidationTask = nil
            windows.removeAll()
            if let source { startFill(from: 0, source: source) }
        }
        if resetMeter { meter.reset() }
    }

    private func scheduleMixInvalidation() {
        mixInvalidationTask?.cancel()
        mixInvalidationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mixInvalidationDebounce)
            guard !Task.isCancelled, let self else { return }
            self.mixInvalidationTask = nil
            self.windows.removeAll()
            if let source = self.source { self.startFill(from: self.lastRequestedSample ?? 0, source: source) }
        }
    }

    // Decode entire timeline outward from anchor, yielding so reactive misses always take priority
    private func startFill(from anchorSample: Int64, source: Source) {
        fillTask?.cancel()
        fillTask = Task { [weak self] in
            guard let durationSeconds = try? await source.asset.load(.duration).seconds,
                  durationSeconds.isFinite, durationSeconds > 0 else { return }
            let stride = Int64(Self.fillStride)
            let totalSamples = Int64(durationSeconds * Self.sampleRate)
            let maxIndex = Int(max(0, (totalSamples - 1) / stride))
            let anchorIndex = max(0, min(maxIndex, Int(anchorSample / stride)))

            // Visit anchor, then anchor-1, anchor+1, anchor-2, anchor+2, … clamped to [0, maxIndex].
            for offset in 0...maxIndex {
                for index in offset == 0 ? [anchorIndex] : [anchorIndex - offset, anchorIndex + offset] {
                    guard index >= 0, index <= maxIndex else { continue }
                    guard !Task.isCancelled, let self, source.generation == self.source?.generation else { return }

                    // Stop before the cap so the resident band stays put; reactive decode covers the rest.
                    guard self.windows.count < Self.fillBudget else { return }
                    let start = Int64(index) * stride
                    if self.hasWindow(startingAt: start) { continue }
                    while self.decodeTask != nil {
                        try? await Task.sleep(for: .milliseconds(20))
                        guard !Task.isCancelled, source.generation == self.source?.generation else { return }
                    }

                    let window = await Self.decodeWindow(source: source, startSample: start, frameCount: Self.cacheFrameCount)
                    guard !Task.isCancelled, source.generation == self.source?.generation else { return }
                    if let window { self.insert(window) }
                }
            }
        }
    }

    private func hasWindow(startingAt startSample: Int64) -> Bool {
        windows.contains { $0.window.startSample == startSample }
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
        if let window = serveableWindow(for: sample) {
            play(request: request, from: window)
            prefetchIfNeeded(sample: sample, direction: direction, from: window, source: source)
        } else {
            requestWindow(around: sample, direction: direction, source: source)
        }
    }

    func meterPlayback(at time: CMTime) {
        guard let source, time.isValid else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let sample = Int64((seconds * Self.sampleRate).rounded())
        latestMeterSample = sample
        if let window = meterableWindow(for: sample) {
            publishMeter(sample: sample, from: window)
            if sample + Int64(Self.meterPrefetchFrameCount) >= window.endSample {
                requestWindow(around: sample, direction: .forward, source: source)
            }
        } else {
            requestWindow(around: sample, direction: .forward, source: source)
        }
    }

    func stopScrubbing() {
        resetScrubState()
        output.stop()
    }

    private func resetScrubState() {
        decodeTask?.cancel()
        decodeTask = nil
        pendingDecodeRange = nil
        latestRequest = nil
        latestMeterSample = nil
        lastRequestedSample = nil
        lastDirection = .forward
    }

    func teardown() {
        resetScrubState()
        mixInvalidationTask?.cancel()
        mixInvalidationTask = nil
        fillTask?.cancel()
        fillTask = nil
        source = nil
        windows.removeAll()
        output.invalidate()
        removeLifecycleObservers()
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            observer.center.removeObserver(observer.token)
        }
        lifecycleObservers.removeAll()
    }

    private func requestWindow(around sample: Int64, direction: Direction, source: Source) {
        if let pendingDecodeRange, canServe(sample: sample, from: pendingDecodeRange) { return }

        decodeTask?.cancel()
        let startSample = windowStart(around: sample, direction: direction)
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
            self.insert(window)

            if let request = self.latestRequest {
                if self.canServe(sample: request.sample, from: window) {
                    self.play(request: request, from: window)
                } else {
                    self.requestWindow(around: request.sample, direction: request.direction, source: source)
                }
                return
            }
            if let meterSample = self.latestMeterSample {
                if self.canMeter(sample: meterSample, from: window) {
                    self.publishMeter(sample: meterSample, from: window)
                } else {
                    self.requestWindow(around: meterSample, direction: .forward, source: source)
                }
            }
        }
    }

    /// Bias the decode window in the scrub direction so most of it lands ahead of the playhead.
    private func windowStart(around sample: Int64, direction: Direction) -> Int64 {
        let behind = Int64(Self.cacheFrameCount / 8)
        let offset: Int64 = direction == .forward ? behind : Int64(Self.cacheFrameCount) - behind
        return max(0, sample - offset)
    }

    private func prefetchIfNeeded(sample: Int64, direction: Direction, from window: PCMWindow, source: Source) {
        guard decodeTask == nil else { return }
        let margin = Int64(Self.prefetchMarginFrameCount)
        let nearEdge = direction == .forward
            ? sample + margin >= window.endSample
            : sample - margin <= window.startSample
        guard nearEdge else { return }
        let step = Int64(Self.cacheFrameCount - Self.prefetchMarginFrameCount)
        let next = direction == .forward ? sample + step : sample - step
        guard next >= 0, serveableWindow(for: next, touch: false) == nil else { return }
        requestWindow(around: next, direction: direction, source: source)
    }

    private func serveableWindow(for sample: Int64, touch: Bool = true) -> PCMWindow? {
        guard let index = windows.firstIndex(where: { canServe(sample: sample, from: $0.window) }) else { return nil }
        if touch {
            useCounter &+= 1
            windows[index].lastUsed = useCounter
        }
        return windows[index].window
    }

    private func meterableWindow(for sample: Int64) -> PCMWindow? {
        guard let index = windows.firstIndex(where: { canMeter(sample: sample, from: $0.window) }) else { return nil }
        useCounter &+= 1
        windows[index].lastUsed = useCounter
        return windows[index].window
    }

    private func insert(_ window: PCMWindow) {
        useCounter &+= 1
        if let index = windows.firstIndex(where: { $0.window.startSample == window.startSample }) {
            windows[index] = CachedWindow(window: window, lastUsed: useCounter)
        } else {
            windows.append(CachedWindow(window: window, lastUsed: useCounter))
        }
        if windows.count > Self.maxCachedWindows,
           let evict = windows.indices.min(by: { windows[$0].lastUsed < windows[$1].lastUsed }) {
            windows.remove(at: evict)
        }
    }

    private func play(request: Request, from window: PCMWindow) {
        latestRequest = nil
        guard window.hasAudioTracks else {
            meter.ingest(.silence)
            output.stop()
            return
        }

        let grain = makeGrain(request: request, from: window)
        meter.ingest(AudioLevelAnalyzer.analyze(
            left: grain.left,
            right: grain.right,
            range: grain.left.indices
        ))
        output.play(grain)
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

    private func makeGrain(request: Request, from window: PCMWindow) -> ScrubAudioGrain {
        let frameCount = Self.grainFrameCount
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)

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
                left[outputIndex] = Float(window.left[cacheIndex]) * Self.int16ToFloat * gain
                right[outputIndex] = Float(window.right[cacheIndex]) * Self.int16ToFloat * gain
            }
        }
        return ScrubAudioGrain(left: left, right: right)
    }

    nonisolated private static let int16ToFloat: Float = 1.0 / 32768.0

    nonisolated private static func quantize(_ sample: Float) -> Int16 {
        Int16((max(-1, min(1, sample)) * 32767).rounded())
    }

    private func observeLifecycle() {
        let appCenter = NotificationCenter.default
        let resignObserver = appCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendOutput()
            }
        }
        lifecycleObservers.append((appCenter, resignObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendOutput()
            }
        }
        lifecycleObservers.append((workspaceCenter, sleepObserver))
    }

    private func suspendOutput() {
        resetScrubState()
        output.invalidate()
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

        var leftSamples = [Int16](repeating: 0, count: frameCount)
        var rightSamples = [Int16](repeating: 0, count: frameCount)
        guard !tracks.isEmpty else {
            return PCMWindow(startSample: startSample, left: leftSamples, right: rightSamples, hasAudioTracks: false)
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
            let rightChannel = channels[min(1, sourceChannelCount - 1)]
            for sourceIndex in 0..<sampleCount {
                let destinationIndex = destinationOffset + sourceIndex
                guard leftSamples.indices.contains(destinationIndex) else { continue }
                leftSamples[destinationIndex] = quantize(channels[0][sourceIndex])
                rightSamples[destinationIndex] = quantize(rightChannel[sourceIndex])
            }
            runningOffset = max(runningOffset, destinationOffset + sampleCount)
        }

        guard reader.status != .failed else { return nil }
        return PCMWindow(startSample: startSample, left: leftSamples, right: rightSamples, hasAudioTracks: true)
    }
}
