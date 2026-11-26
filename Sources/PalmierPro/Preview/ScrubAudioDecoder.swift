import AVFoundation
import os

actor ScrubAudioDecoder {
    static let shared = ScrubAudioDecoder()

    // Safety: retained assets/mixes are immutable; only async loading and the admitted queue use them.
    struct Source: @unchecked Sendable {
        let asset: AVAsset
        let audioMix: AVAudioMix?
        let generation: Int
    }

    struct PCMWindow: Sendable {
        let startSample: Int64
        let left: [Int16]
        let right: [Int16]
        let hasAudioTracks: Bool

        var endSample: Int64 { startSample + Int64(left.count) }
    }

    enum Outcome: Sendable {
        case success(PCMWindow)
        case cancelled
        case timedOut
        case failure
    }

    final class Cancellation: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { state.withLock { $0 } }
        func cancel() { state.withLock { $0 = true } }
        func check() throws {
            if isCancelled { throw CancellationError() }
        }
    }

    typealias Read = @Sendable (Cancellation) throws -> PCMWindow
    typealias Prepare = @Sendable () async throws -> Read

    private struct Request {
        let id: UUID
        let cancellation: Cancellation
        let prepare: Prepare
        var completion: (@Sendable (Outcome) -> Void)?
        var timer: Task<Void, Never>?
    }

    // Safety: the key and queue are immutable; reader objects exist only inside queue operations.
    private final class ReaderQueue: @unchecked Sendable {
        let queue = DispatchQueue(label: "io.palmier.pro.scrub-audio-reader", qos: .utility)
        let key = DispatchSpecificKey<Bool>()

        init() { queue.setSpecific(key: key, value: true) }
        var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }
    }

    private nonisolated let readerQueue = ReaderQueue()
    private let requestRegistered: (@Sendable (UUID) -> Void)?

    init(requestRegistered: (@Sendable (UUID) -> Void)? = nil) {
        self.requestRegistered = requestRegistered
    }

    var pendingRequestID: UUID? { pending?.id }

    private var preparationTask: Task<Void, Never>?
    private var active: Request?
    private var pending: Request?
    private var admissionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    // This bounds caller wait, including loading; a blocked reader keeps physical admission occupied.
    private static let decodeDeadline = Duration.seconds(5)

    nonisolated var isOnReaderQueue: Bool { readerQueue.isCurrent }

    nonisolated func decode(id: UUID = UUID(), source: Source, startSample: Int64, frameCount: Int) async -> Outcome {
        await submit(id: id) {
            let tracks = try await source.asset.loadTracks(withMediaType: .audio)
            let loaded = LoadedSource(source: source, tracks: tracks)
            return { cancellation in
                try self.read(loaded, startSample: startSample, frameCount: frameCount, cancellation: cancellation)
            }
        }
    }

    nonisolated func submit(id: UUID = UUID(), prepare: @escaping Prepare) async -> Outcome {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task {
                    await self.register(id: id, cancellation: cancellation, prepare: prepare) {
                        continuation.resume(returning: $0)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(id: id) }
        }
    }

    nonisolated func waitForActiveDecode() async {
        let id = UUID()
        let cancellation = Cancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await self.waitForActiveDecode(id: id, cancellation: cancellation, continuation: continuation) }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.resumeAdmissionWaiter(id: id) }
        }
    }

    private func waitForActiveDecode(
        id: UUID, cancellation: Cancellation, continuation: CheckedContinuation<Void, Never>
    ) {
        guard active != nil, !cancellation.isCancelled else { continuation.resume(); return }
        admissionWaiters[id] = continuation
    }

    private func resumeAdmissionWaiter(id: UUID) {
        admissionWaiters.removeValue(forKey: id)?.resume()
    }

    func register(
        id: UUID,
        cancellation: Cancellation,
        prepare: @escaping Prepare,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        guard !cancellation.isCancelled else {
            completion(.cancelled)
            return
        }
        var request = Request(id: id, cancellation: cancellation, prepare: prepare, completion: completion)
        request.timer = Task { [weak self] in
            do { try await Task.sleep(for: Self.decodeDeadline) } catch { return }
            await self?.expire(id: id)
        }
        if active == nil {
            start(request)
        } else {
            if var displaced = pending { complete(&displaced, outcome: .cancelled) }
            pending = request
        }
        requestRegistered?(id)
    }

    private func complete(_ request: inout Request, outcome: Outcome) {
        request.cancellation.cancel()
        request.timer?.cancel()
        request.timer = nil
        request.completion?(outcome)
        request.completion = nil
    }

    func expire(id: UUID) {
        guard active?.id == id || pending?.id == id else { return }
        if active?.id == id, active?.completion == nil { return }
        Log.preview.warning("Scrub audio decode timed out after \(String(describing: Self.decodeDeadline)); storage may be unavailable. Reader admission remains occupied until teardown.")
        invalidate(id: id, outcome: .timedOut)
    }

    func cancel(id: UUID) {
        invalidate(id: id, outcome: .cancelled)
    }

    private func invalidate(id: UUID, outcome: Outcome) {
        if active?.id == id {
            complete(&active!, outcome: outcome)
            preparationTask?.cancel()
        } else if pending?.id == id {
            complete(&pending!, outcome: outcome)
            pending = nil
        }
    }

    private func start(_ request: Request) {
        active = request
        let id = request.id
        let cancellation = request.cancellation
        let prepare = request.prepare
        preparationTask = Task {
            do {
                try cancellation.check()
                let read = try await prepare()
                try cancellation.check()
                preparationTask = nil
                readerQueue.queue.async {
                    let result: Outcome = autoreleasepool {
                        do {
                            try cancellation.check()
                            let window = try read(cancellation)
                            try cancellation.check()
                            return .success(window)
                        } catch is CancellationError {
                            return .cancelled
                        } catch {
                            return .failure
                        }
                    }
                    Task { await self.finished(id: id, outcome: result) }
                }
            } catch is CancellationError {
                finished(id: id, outcome: .cancelled)
            } catch {
                finished(id: id, outcome: .failure)
            }
        }
    }

    private func finished(id: UUID, outcome: Outcome) {
        guard var request = active, request.id == id else { return }
        if request.completion != nil {
            let result: Outcome = request.cancellation.isCancelled ? .cancelled : outcome
            if case .failure = result {
                Log.preview.warning("Scrub audio decode failed during loading or reading; check media availability and format.")
            }
            complete(&request, outcome: result)
        }
        preparationTask = nil
        active = nil
        let waiters = admissionWaiters.values
        admissionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if let next = pending {
            pending = nil
            start(next)
        }
    }

    // Safety: loaded tracks cross once from async loading into the exclusively admitted reader queue.
    private struct LoadedSource: @unchecked Sendable {
        let source: Source
        let tracks: [AVAssetTrack]
    }

    private enum ReadError: Error { case unavailable }

    private nonisolated func read(
        _ loaded: LoadedSource,
        startSample: Int64,
        frameCount: Int,
        cancellation: Cancellation
    ) throws -> PCMWindow {
        precondition(isOnReaderQueue && !Thread.isMainThread)
        try cancellation.check()
        var left = [Int16](repeating: 0, count: frameCount)
        var right = left
        guard !loaded.tracks.isEmpty else {
            return PCMWindow(startSample: startSample, left: left, right: right, hasAudioTracks: false)
        }
        let reader = try AVAssetReader(asset: loaded.source.asset)
        defer {
            precondition(isOnReaderQueue && !Thread.isMainThread)
            reader.cancelReading()
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: loaded.tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: ScrubAudioEngine.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        output.audioMix = loaded.source.audioMix
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(
            start: CMTime(value: startSample, timescale: CMTimeScale(ScrubAudioEngine.sampleRate)),
            duration: CMTime(value: Int64(frameCount), timescale: CMTimeScale(ScrubAudioEngine.sampleRate))
        )
        guard reader.canAdd(output) else { throw ReadError.unavailable }
        reader.add(output)
        try cancellation.check()
        guard reader.startReading() else { throw reader.error ?? ReadError.unavailable }
        var runningOffset = 0
        while true {
            try cancellation.check()
            let hasSample = try autoreleasepool {
                precondition(isOnReaderQueue && !Thread.isMainThread)
                guard let sampleBuffer = output.copyNextSampleBuffer() else { return false }
                try cancellation.check()
                guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      let format = AVAudioFormat(streamDescription: stream)
                else { return true }
                let count = CMSampleBufferGetNumSamples(sampleBuffer)
                guard count > 0 else { return true }
                guard count <= Int(Int32.max), format.channelCount > 0,
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
                else { return true }
                pcm.frameLength = AVAudioFrameCount(count)
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList
                ) == noErr, let channels = pcm.floatChannelData else { return true }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let offset: Int
                if time.isNumeric {
                    let delta = CMTimeConvertScale(time, timescale: CMTimeScale(ScrubAudioEngine.sampleRate), method: .roundHalfAwayFromZero).value
                    let (relative, overflow) = delta.subtractingReportingOverflow(startSample)
                    guard !overflow, relative >= -Int64(count), relative <= Int64(frameCount) else { return true }
                    offset = Int(relative)
                } else {
                    offset = runningOffset
                }
                let rightChannel = channels[min(1, Int(format.channelCount) - 1)]
                for index in 0..<count {
                    let destination = offset + index
                    guard left.indices.contains(destination) else { continue }
                    left[destination] = Self.quantize(channels[0][index])
                    right[destination] = Self.quantize(rightChannel[index])
                }
                runningOffset = max(runningOffset, offset + count)
                return true
            }
            if !hasSample { break }
        }
        try cancellation.check()
        guard reader.status == .completed else { throw reader.error ?? ReadError.unavailable }
        return PCMWindow(startSample: startSample, left: left, right: right, hasAudioTracks: true)
    }

    private nonisolated static func quantize(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        return Int16((max(-1, min(1, sample)) * 32767).rounded())
    }
}
