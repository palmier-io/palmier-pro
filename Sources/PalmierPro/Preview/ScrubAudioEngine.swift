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
        let inserted: UInt64
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
        let anchor = lastRequestedSample ?? 0
        stopScrubbing()
        cancelFill()
        sourceGeneration &+= 1
        source = asset.map { Source(asset: $0, audioMix: audioMix, generation: sourceGeneration) }
        if mixOnlyChange {
            scheduleMixInvalidation(anchor: anchor)
        } else {
            mixInvalidationTask?.cancel()
            mixInvalidationTask = nil
            windows.removeAll()
            if let source { startFill(from: anchor, source: source) }
        }
        if resetMeter { meter.reset() }
    }

    private func scheduleMixInvalidation(anchor: Int64) {
        mixInvalidationTask?.cancel()
        mixInvalidationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mixInvalidationDebounce)
            guard !Task.isCancelled, let self else { return }
            self.mixInvalidationTask = nil
            self.windows.removeAll()
            if let source = self.source { self.startFill(from: self.lastRequestedSample ?? anchor, source: source) }
        }
    }

    private func cancelFill() {
        fillTask?.cancel()
        fillTask = nil
    }

    // Fill with two passes: anchor→end, then start→anchor for faster preview. One AVAssetReader per pass.
    private func startFill(from anchorSample: Int64, source: Source) {
        cancelFill()
        fillTask = Task { [weak self] in
            guard let durationSeconds = try? await source.asset.load(.duration).seconds,
                  durationSeconds.isFinite, durationSeconds > 0 else { return }
            let totalSamples = Int64(durationSeconds * Self.sampleRate)
            let anchor = max(0, min(totalSamples, anchorSample))

            await self?.streamFill(from: anchor, to: totalSamples, source: source)
            await self?.streamFill(from: 0, to: anchor, source: source)
        }
    }

    // Decode [start, end) with one reader; closure returns false to stop early.
    private func streamFill(from start: Int64, to end: Int64, source: Source) async {
        guard start < end else { return }
        await Self.streamWindows(source: source, from: start, to: end) { [weak self] window in
            guard let self else { return false }
            guard !Task.isCancelled, source.generation == self.source?.generation else { return false }
            guard self.windows.count < Self.fillBudget else { return false }
            if !self.hasWindow(startingAt: window.startSample) { self.insert(window) }
            while self.decodeTask != nil {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, source.generation == self.source?.generation else { return false }
            }
            return true
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
        cancelFill()
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
        guard let index = freshestWindowIndex(where: { canServe(sample: sample, from: $0) }) else { return nil }
        if touch {
            useCounter &+= 1
            windows[index].lastUsed = useCounter
        }
        return windows[index].window
    }

    private func meterableWindow(for sample: Int64) -> PCMWindow? {
        guard let index = freshestWindowIndex(where: { canMeter(sample: sample, from: $0) }) else { return nil }
        useCounter &+= 1
        windows[index].lastUsed = useCounter
        return windows[index].window
    }

    private func freshestWindowIndex(where covers: (PCMWindow) -> Bool) -> Int? {
        windows.indices
            .filter { covers(windows[$0].window) }
            .max(by: { windows[$0].inserted < windows[$1].inserted })
    }

    private func insert(_ window: PCMWindow) {
        useCounter &+= 1
        if let index = windows.firstIndex(where: { $0.window.startSample == window.startSample }) {
            windows[index] = CachedWindow(window: window, lastUsed: useCounter, inserted: useCounter)
        } else {
            windows.append(CachedWindow(window: window, lastUsed: useCounter, inserted: useCounter))
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
            ? AudioLevelAnalyzer.analyzeInt16(left: window.left, right: window.right, range: range)
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

    nonisolated private static let int16ToFloat: Float = 1.0 / 32767.0  // matches quantize scale so full-scale = 1.0

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
        cancelFill()
        output.invalidate()
    }

    private static func edgeGain(at index: Int, frameCount: Int) -> Float {
        let fadeIn = min(1, Float(index + 1) / Float(fadeFrameCount))
        let fadeOut = min(1, Float(frameCount - index) / Float(fadeFrameCount))
        return min(fadeIn, fadeOut)
    }

    nonisolated private static func makeReader(
        source: Source,
        tracks: [AVAssetTrack],
        startSample: Int64,
        frameCount: Int64
    ) -> (AVAssetReader, AVAssetReaderAudioMixOutput)? {
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
            duration: CMTime(value: frameCount, timescale: sampleTimescale)
        )
        guard reader.startReading() else { return nil }
        return (reader, output)
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

        guard let (reader, output) = makeReader(
            source: source, tracks: tracks, startSample: startSample, frameCount: Int64(frameCount)
        ) else { return nil }

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

        guard reader.status == .completed else { return nil }
        return PCMWindow(startSample: startSample, left: leftSamples, right: rightSamples, hasAudioTracks: true)
    }

    @concurrent
    private static func streamWindows(
        source: Source,
        from: Int64,
        to: Int64,
        emit: @MainActor (PCMWindow) async -> Bool
    ) async {
        guard let tracks = try? await source.asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let (reader, output) = makeReader(
                source: source, tracks: tracks, startSample: from, frameCount: to - from
              ) else { return }

        let windowLen = cacheFrameCount
        let stride = Int64(fillStride)
        var bufferStart = from            // absolute sample of left[0]/right[0]
        var left = [Int16]()
        var right = [Int16]()
        var filledEnd = from              // absolute sample one past the last written

        func drainFull() async -> Bool {
            while filledEnd - bufferStart >= Int64(windowLen) {
                let window = PCMWindow(
                    startSample: bufferStart,
                    left: Array(left[0..<windowLen]),
                    right: Array(right[0..<windowLen]),
                    hasAudioTracks: true
                )
                if !(await emit(window)) { return false }
                left.removeFirst(Int(stride))
                right.removeFirst(Int(stride))
                bufferStart += stride
            }
            return true
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let sampleFormat = AVAudioFormat(streamDescription: streamDescription)
            else { continue }

            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleCount > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: sampleFormat, frameCapacity: AVAudioFrameCount(sampleCount))
            else { continue }
            pcm.frameLength = AVAudioFrameCount(sampleCount)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(sampleCount), into: pcm.mutableAudioBufferList
            ) == noErr, let channels = pcm.floatChannelData else { continue }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let abs = presentationTime.isValid
                ? Int64((presentationTime.seconds * sampleRate).rounded())
                : filledEnd
            let base = Int(abs - bufferStart)
            let sourceStart = max(0, -base)
            guard sourceStart < sampleCount else { continue }

            let neededCount = base + sampleCount
            if left.count < neededCount {
                left.append(contentsOf: repeatElement(0, count: neededCount - left.count))
                right.append(contentsOf: repeatElement(0, count: neededCount - right.count))
            }
            let sourceChannelCount = Int(sampleFormat.channelCount)
            let rightChannel = channels[min(1, sourceChannelCount - 1)]
            for sourceIndex in sourceStart..<sampleCount {
                left[base + sourceIndex] = quantize(channels[0][sourceIndex])
                right[base + sourceIndex] = quantize(rightChannel[sourceIndex])
            }
            filledEnd = max(filledEnd, abs + Int64(sampleCount))
            if !(await drainFull()) { reader.cancelReading(); return }
        }

        guard reader.status == .completed else { return }
        // Flush the final tail as a zero-padded window so coverage reaches `to`.
        if filledEnd > bufferStart {
            if left.count < windowLen {
                left.append(contentsOf: repeatElement(0, count: windowLen - left.count))
                right.append(contentsOf: repeatElement(0, count: windowLen - right.count))
            }
            let window = PCMWindow(
                startSample: bufferStart,
                left: Array(left[0..<windowLen]),
                right: Array(right[0..<windowLen]),
                hasAudioTracks: true
            )
            _ = await emit(window)
        }
    }
}
