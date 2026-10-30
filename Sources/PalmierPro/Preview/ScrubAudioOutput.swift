import AVFoundation
import os

struct ScrubAudioGrain: Sendable {
    let left: [Float]
    let right: [Float]
}

struct ScrubAudioOutputState: Equatable, Sendable {
    enum GraphState: Equatable, Sendable {
        case missing
        case stopped
        case running
    }

    private(set) var graph: GraphState = .missing
    private(set) var playerStarted = false

    mutating func graphPrepared() {
        graph = .stopped
        playerStarted = false
    }

    mutating func engineStarted() {
        graph = .running
    }

    mutating func startPlayerIfNeeded() -> Bool {
        guard graph == .running, !playerStarted else { return false }
        playerStarted = true
        return true
    }

    mutating func stop() {
        if graph != .missing { graph = .stopped }
        playerStarted = false
    }

    mutating func invalidate() {
        graph = .missing
        playerStarted = false
    }
}

struct ScrubAudioPendingState<Value: Sendable>: Sendable {
    private(set) var generation: UInt = 0
    private(set) var drainGeneration: UInt?
    private var pending: Value?

    mutating func submit(_ value: Value) -> UInt? {
        pending = value
        guard drainGeneration == nil else { return nil }
        drainGeneration = generation
        return generation
    }

    mutating func take(for generation: UInt) -> Value? {
        guard self.generation == generation else { return nil }
        defer { pending = nil }
        return pending
    }

    mutating func finishDrain(for generation: UInt) -> UInt? {
        guard drainGeneration == generation else { return nil }
        drainGeneration = nil
        guard pending != nil else { return nil }
        drainGeneration = self.generation
        return self.generation
    }

    mutating func cancel() {
        generation &+= 1
        pending = nil
        // Keep the old drain claimed so replacement work runs after queued lifecycle operations.
    }

    func isCurrent(_ generation: UInt) -> Bool {
        self.generation == generation
    }
}

final class ScrubAudioOutput: @unchecked Sendable {
    private static let channelCount: AVAudioChannelCount = 2

    // Core Audio operations stay off the main thread because they may block.
    private let queue = DispatchQueue(label: "io.palmier.pro.scrub-audio-output", qos: .userInteractive)
    private let pending = OSAllocatedUnfairLock(initialState: ScrubAudioPendingState<ScrubAudioGrain>())
    private let sampleRate: Double
    private var state = ScrubAudioOutputState()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var silenceBuffer: AVAudioPCMBuffer?
    private var configurationObserver: NSObjectProtocol?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func play(_ grain: ScrubAudioGrain) {
        let generation = pending.withLock { state in
            state.submit(grain)
        }
        guard let generation else { return }
        scheduleDrain(generation: generation)
    }

    func stop() {
        cancelPending()
        queue.async { [self] in
            stopOnQueue()
        }
    }

    func invalidate() {
        cancelPending()
        queue.async { [self] in
            invalidateOnQueue()
        }
    }

    private func scheduleDrain(generation: UInt) {
        queue.async { [self] in
            drain(generation: generation)
        }
    }

    private func drain(generation: UInt) {
        while let grain = pending.withLock({ state in state.take(for: generation) }) {
            let isCurrent = pending.withLock { state in state.isCurrent(generation) }
            guard isCurrent else { break }
            playOnQueue(grain)
        }

        let nextGeneration = pending.withLock { state in
            state.finishDrain(for: generation)
        }
        if let nextGeneration {
            scheduleDrain(generation: nextGeneration)
        }
    }

    private func cancelPending() {
        pending.withLock { state in
            state.cancel()
        }
    }

    private func playOnQueue(_ grain: ScrubAudioGrain) {
        guard let player = prepareOutputIfNeeded(),
              let format,
              let silenceBuffer,
              let buffer = makeBuffer(grain, format: format)
        else { return }

        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        // Keep the player alive between grains so play() runs once per scrub session.
        player.scheduleBuffer(silenceBuffer, at: nil, options: .loops)
        if state.startPlayerIfNeeded() {
            player.play()
        }
    }

    private func prepareOutputIfNeeded() -> AVAudioPlayerNode? {
        if state.graph == .missing {
            guard prepareGraph() else { return nil }
        }
        guard let engine, let player else { return nil }
        if state.graph != .running {
            engine.prepare()
            do {
                try engine.start()
                state.engineStarted()
            } catch {
                Log.preview.error("scrub audio engine failed: \(error.localizedDescription)")
                cancelPending()
                invalidateOnQueue()
                return nil
            }
        }
        return player
    }

    private func prepareGraph() -> Bool {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: Self.channelCount,
            interleaved: false
        ), let silenceBuffer = makeSilenceBuffer(format: format) else { return false }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        self.engine = engine
        self.player = player
        self.format = format
        self.silenceBuffer = silenceBuffer
        state.graphPrepared()

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
        return true
    }

    private func stopOnQueue() {
        player?.stop()
        engine?.stop()
        state.stop()
    }

    private func invalidateOnQueue() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        player?.stop()
        engine?.stop()
        engine?.reset()
        player = nil
        engine = nil
        format = nil
        silenceBuffer = nil
        state.invalidate()
    }

    private func makeBuffer(_ grain: ScrubAudioGrain, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = min(grain.left.count, grain.right.count)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ), let channels = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        grain.left.withUnsafeBufferPointer { source in
            channels[0].update(from: source.baseAddress!, count: frameCount)
        }
        grain.right.withUnsafeBufferPointer { source in
            channels[1].update(from: source.baseAddress!, count: frameCount)
        }
        return buffer
    }

    private func makeSilenceBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(256)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        for channel in 0..<Int(Self.channelCount) {
            channels[channel].initialize(repeating: 0, count: Int(frameCount))
        }
        return buffer
    }
}
