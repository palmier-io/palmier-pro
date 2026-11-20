import AppKit
import AVFoundation

@MainActor
final class ScrubAudioEngine {
    private enum Direction: Sendable {
        case forward
        case reverse
    }

    private typealias Source = ScrubAudioDecoder.Source
    private typealias PCMWindow = ScrubAudioDecoder.PCMWindow

    private struct Request: Sendable {
        let sample: Int64
        let direction: Direction
    }

    private struct CachedWindow {
        let window: PCMWindow
        var lastUsed: UInt64
        let inserted: UInt64
    }

    nonisolated static let sampleRate = 48_000.0
    nonisolated private static let cacheFrameCount = 96_000
    nonisolated private static let grainFrameCount = 2_400
    nonisolated private static let fadeFrameCount = 144
    nonisolated private static let meterFrameCount = 960
    nonisolated private static let meterPrefetchFrameCount = 12_000
    nonisolated private static let prefetchMarginFrameCount = 24_000
    nonisolated private static let maxCachedWindows = 256
    nonisolated private static let mixInvalidationDebounce = Duration.milliseconds(250)
    nonisolated private static let failedDecodeRetryDelay = Duration.seconds(1)

    private let decoder: ScrubAudioDecoder
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
    private(set) var decodeTask: Task<Void, Never>?
    private(set) var pendingDecodeID: UUID?
    private var pendingDecodeRange: Range<Int64>?
    private var lastFailedDecode: FailedDecode?
    private var mixInvalidationTask: Task<Void, Never>?
    private var lifecycleObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private struct FailedDecode {
        let range: Range<Int64>
        let generation: Int
        let at: ContinuousClock.Instant
    }

    init(meter: AudioMeterHub, decoder: ScrubAudioDecoder = .shared) {
        self.decoder = decoder
        self.meter = meter
        observeLifecycle()
    }

    isolated deinit {
        teardown()
    }

    func configure(asset: AVAsset?, audioMix: AVAudioMix?, resetMeter: Bool = true) {
        let mixOnlyChange = asset != nil && asset === source?.asset
        stopScrubbing()
        sourceGeneration &+= 1
        source = asset.map { Source(asset: $0, audioMix: audioMix, generation: sourceGeneration) }
        if mixOnlyChange {
            scheduleMixInvalidation()
        } else {
            mixInvalidationTask?.cancel()
            mixInvalidationTask = nil
            windows.removeAll()
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
        }
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

    func stopPlaybackMetering() {
        latestMeterSample = nil
        if latestRequest == nil {
            decodeTask?.cancel()
            decodeTask = nil
            pendingDecodeID = nil
            pendingDecodeRange = nil
        }
        meter.reset()
    }

    func stopScrubbing() {
        resetScrubState()
        output.stop()
    }

    private func resetScrubState() {
        decodeTask?.cancel()
        decodeTask = nil
        pendingDecodeID = nil
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
        // Persistently failing media (offline volume, corrupt file) must not spawn a reader per meter tick.
        if let failure = lastFailedDecode,
           failure.generation == source.generation,
           failure.range.contains(sample),
           ContinuousClock.now - failure.at < Self.failedDecodeRetryDelay {
            return
        }

        decodeTask?.cancel()
        let startSample = windowStart(around: sample, direction: direction)
        let range = startSample..<(startSample + Int64(Self.cacheFrameCount))
        let requestID = UUID()
        pendingDecodeID = requestID
        pendingDecodeRange = range

        let decoder = decoder
        decodeTask = Task { [weak self] in
            let outcome = await decoder.decode(
                id: requestID, source: source,
                startSample: startSample,
                frameCount: Self.cacheFrameCount
            )
            guard !Task.isCancelled, let self else { return }
            self.completeDecode(outcome, requestID: requestID, generation: source.generation, range: range)
        }
    }

    func completeDecode(
        _ outcome: ScrubAudioDecoder.Outcome, requestID: UUID, generation: Int, range: Range<Int64>
    ) {
        guard pendingDecodeID == requestID, let source, source.generation == generation else { return }
        decodeTask = nil
        pendingDecodeID = nil
        pendingDecodeRange = nil
        let window: PCMWindow
        switch outcome {
        case .success(let decoded):
            window = decoded
        case .cancelled:
            pendingDecodeID = requestID
            pendingDecodeRange = range
            decodeTask = Task { [weak self, decoder] in
                await decoder.waitForActiveDecode()
                guard !Task.isCancelled, let self,
                      self.pendingDecodeID == requestID,
                      self.source?.generation == generation else { return }
                self.pendingDecodeID = nil
                self.decodeTask = nil
                if let request = self.latestRequest {
                    self.requestWindow(around: request.sample, direction: request.direction, source: source)
                } else if let sample = self.latestMeterSample {
                    self.requestWindow(around: sample, direction: .forward, source: source)
                }
            }
            return
        case .timedOut, .failure:
            lastFailedDecode = FailedDecode(range: range, generation: generation, at: .now)
            if latestRequest != nil { lastRequestedSample = nil }
            return
        }
        lastFailedDecode = nil
        insert(window)

        if let request = latestRequest {
            if canServe(sample: request.sample, from: window) {
                play(request: request, from: window)
            } else {
                requestWindow(around: request.sample, direction: request.direction, source: source)
            }
            return
        }
        if let meterSample = latestMeterSample {
            if canMeter(sample: meterSample, from: window) {
                publishMeter(sample: meterSample, from: window)
            } else {
                requestWindow(around: meterSample, direction: .forward, source: source)
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
        cachedWindow(where: { canServe(sample: sample, from: $0) }, touch: touch)
    }

    private func meterableWindow(for sample: Int64) -> PCMWindow? {
        cachedWindow(where: { canMeter(sample: sample, from: $0) }, touch: true)
    }

    // Prefer the most recently inserted covering window so a fresh mix supersedes stale decodes.
    private func cachedWindow(where covers: (PCMWindow) -> Bool, touch: Bool) -> PCMWindow? {
        guard let index = windows.indices
            .filter({ covers(windows[$0].window) })
            .max(by: { windows[$0].inserted < windows[$1].inserted })
        else { return nil }
        if touch {
            useCounter &+= 1
            windows[index].lastUsed = useCounter
        }
        return windows[index].window
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

}
