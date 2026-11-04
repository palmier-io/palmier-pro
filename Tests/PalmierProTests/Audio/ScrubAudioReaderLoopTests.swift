import AVFoundation
import os
import Testing
@testable import PalmierPro

@Suite("Scrub audio reader loop")
struct ScrubAudioReaderLoopTests {
    @Test(arguments: [false, true])
    func invalidationRetainsPhysicalAdmissionUntilTeardown(timeout: Bool) async throws {
        let decoder = ScrubAudioDecoder()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = AsyncStream<Void>.makeStream()
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let first = await enqueue(decoder) { cancellation in
            #expect(decoder.isOnReaderQueue && !Thread.isMainThread)
            events.withLock { $0.append("setup") }
            defer {
                #expect(decoder.isOnReaderQueue && !Thread.isMainThread)
                events.withLock { $0.append("teardown") }
            }
            #expect(decoder.isOnReaderQueue && !Thread.isMainThread)
            events.withLock { $0.append("read") }
            started.continuation.yield(())
            gate.wait()
            #expect(cancellation.isCancelled)
            return ScrubAudioDecoder.PCMWindow(startSample: 0, left: [1], right: [1], hasAudioTracks: true)
        }
        for await _ in started.stream { break }
        if timeout {
            await decoder.expire(id: first.id)
            await decoder.cancel(id: first.id)
        } else {
            await decoder.cancel(id: first.id)
            await decoder.expire(id: first.id)
        }
        var firstResults = first.results.makeAsyncIterator()
        let result = try #require(await firstResults.next())
        if timeout {
            guard case .timedOut = result else { Issue.record("Expected timeout"); gate.signal(); return }
        } else {
            guard case .cancelled = result else { Issue.record("Expected cancellation"); gate.signal(); return }
        }
        #expect(await firstResults.next() == nil)
        let cancelledPending = await enqueue(decoder) { _ in
            Issue.record("Cancelled pending work must not create a reader")
            return ScrubAudioDecoder.PCMWindow(startSample: 1, left: [], right: [], hasAudioTracks: false)
        }
        await decoder.cancel(id: cancelledPending.id)
        var cancelledResults = cancelledPending.results.makeAsyncIterator()
        guard case .cancelled = await cancelledResults.next() else {
            Issue.record("Expected pending cancellation"); gate.signal(); return
        }
        #expect(await cancelledResults.next() == nil)
        let displaced = await enqueue(decoder) { _ in
            Issue.record("Superseded pending work must not create a reader")
            return ScrubAudioDecoder.PCMWindow(startSample: 1, left: [], right: [], hasAudioTracks: false)
        }
        let latest = await enqueue(decoder) { _ in
            #expect(decoder.isOnReaderQueue && !Thread.isMainThread)
            events.withLock { $0.append("replacement") }
            return ScrubAudioDecoder.PCMWindow(startSample: 2, left: [2], right: [2], hasAudioTracks: true)
        }
        var displacedResults = displaced.results.makeAsyncIterator()
        guard case .cancelled = await displacedResults.next() else {
            Issue.record("Expected displaced cancellation"); gate.signal(); return
        }
        #expect(await displacedResults.next() == nil)
        #expect(events.withLock { $0 } == ["setup", "read"])
        gate.signal()
        var latestResults = latest.results.makeAsyncIterator()
        guard case .success(let window) = await latestResults.next() else {
            Issue.record("Expected latest request to succeed"); return
        }
        #expect(window.startSample == 2 && window.left == [2])
        #expect(events.withLock { $0 } == ["setup", "read", "teardown", "replacement"])
        await decoder.cancel(id: latest.id)
        await decoder.expire(id: latest.id)
        #expect(await latestResults.next() == nil)
    }

    @Test func cancellationDuringLoadingDoesNotReleaseAdmission() async {
        let decoder = ScrubAudioDecoder()
        let loading = AsyncStream<Void>.makeStream()
        let release = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let cancellation = ScrubAudioDecoder.Cancellation()
        let results = AsyncStream<ScrubAudioDecoder.Outcome>.makeStream()
        let id = UUID()
        await decoder.register(id: id, cancellation: cancellation, prepare: {
            await withCheckedContinuation { continuation in
                release.withLock { $0 = continuation }
                loading.continuation.yield(())
            }
            return { _ in
                Issue.record("Cancelled loading must not construct a reader")
                return ScrubAudioDecoder.PCMWindow(startSample: 0, left: [], right: [], hasAudioTracks: false)
            }
        }, completion: {
            results.continuation.yield($0)
            results.continuation.finish()
        })
        for await _ in loading.stream { break }
        await decoder.cancel(id: id)
        let next = await enqueue(decoder) { _ in
            ScrubAudioDecoder.PCMWindow(startSample: 1, left: [], right: [], hasAudioTracks: false)
        }
        var iterator = results.stream.makeAsyncIterator()
        guard case .cancelled = await iterator.next() else { Issue.record("Expected cancellation"); return }
        #expect(await iterator.next() == nil)
        #expect(await decoder.pendingRequestID == next.id)
        release.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
        var nextIterator = next.results.makeAsyncIterator()
        guard case .success = await nextIterator.next() else { Issue.record("Expected next decode"); return }
    }

    @Test func cancellationBeforeRegistrationSkipsPreparation() async {
        let decoder = ScrubAudioDecoder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await decoder.submit {
                Issue.record("Cancelled submission must not load tracks")
                return { _ in ScrubAudioDecoder.PCMWindow(startSample: 0, left: [], right: [], hasAudioTracks: false) }
            }
        }
        guard case .cancelled = await task.value else { Issue.record("Expected cancellation"); return }
    }

    @Test @MainActor func staleEngineCompletionCannotClearReplacementOrStoppedIntent() async throws {
        let decoder = ScrubAudioDecoder()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = AsyncStream<Void>.makeStream()
        let blocker = await enqueue(decoder) { _ in
            started.continuation.yield(())
            gate.wait()
            return ScrubAudioDecoder.PCMWindow(startSample: 0, left: [], right: [], hasAudioTracks: false)
        }
        for await _ in started.stream { break }
        let meter = AudioMeterHub()
        let engine = ScrubAudioEngine(meter: meter, decoder: decoder)
        defer { engine.teardown() }
        engine.configure(asset: AVMutableComposition(), audioMix: nil)
        engine.meterPlayback(at: .zero)
        let oldTask = try #require(engine.decodeTask)
        let oldID = try #require(engine.pendingDecodeID)
        engine.configure(asset: AVMutableComposition(), audioMix: nil)
        engine.meterPlayback(at: .zero)
        let replacementID = try #require(engine.pendingDecodeID)
        let replacement = try #require(engine.decodeTask)
        let stale = ScrubAudioDecoder.Outcome.success(.init(
            startSample: 0, left: Array(repeating: 16_384, count: 96_000),
            right: Array(repeating: 16_384, count: 96_000), hasAudioTracks: true
        ))
        engine.completeDecode(stale, requestID: oldID, generation: 2, range: 0..<96_000)
        #expect(engine.pendingDecodeID == replacementID)
        engine.completeDecode(stale, requestID: replacementID, generation: 1, range: 0..<96_000)
        #expect(engine.pendingDecodeID == replacementID)
        engine.meterPlayback(at: CMTime(value: 1, timescale: 48_000))
        #expect(engine.pendingDecodeID == replacementID)
        #expect(meter.display().left.levelDb == AudioMeterChannelState.floorDb)
        await oldTask.value
        #expect(engine.pendingDecodeID == replacementID)
        engine.stopPlaybackMetering()
        await replacement.value
        engine.completeDecode(stale, requestID: replacementID, generation: 2, range: 0..<96_000)
        #expect(engine.pendingDecodeID == nil)
        #expect(meter.display().left.levelDb == AudioMeterChannelState.floorDb)
        gate.signal()
        var iterator = blocker.results.makeAsyncIterator()
        guard case .success = await iterator.next() else { Issue.record("Expected blocker completion"); return }
        #expect(engine.pendingDecodeID == nil)
    }

    @Test(arguments: [false, true])
    @MainActor func displacedEngineWaitsForAdmissionAndHonorsStop(stop: Bool) async throws {
        let url = try await makeAudioFixture()
        do {
            let registrations = AsyncStream<UUID>.makeStream()
            let decoder = ScrubAudioDecoder(requestRegistered: { registrations.continuation.yield($0) })
            var registered = registrations.stream.makeAsyncIterator()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let started = AsyncStream<Void>.makeStream()
            let blocker = await enqueue(decoder) { _ in
                started.continuation.yield(())
                gate.wait()
                return .init(startSample: 0, left: [], right: [], hasAudioTracks: false)
            }
            #expect(await registered.next() == blocker.id)
            for await _ in started.stream { break }
            let meter = AudioMeterHub()
            let engine = ScrubAudioEngine(meter: meter, decoder: decoder)
            let otherMeter = AudioMeterHub()
            let otherEngine = ScrubAudioEngine(meter: otherMeter, decoder: decoder)
            defer { engine.teardown(); otherEngine.teardown() }
            engine.configure(asset: AVURLAsset(url: url), audioMix: nil)
            engine.meterPlayback(at: .zero)
            let firstID = try #require(engine.pendingDecodeID)
            let firstTask = try #require(engine.decodeTask)
            #expect(await registered.next() == firstID)
            #expect(await decoder.pendingRequestID == firstID)
            otherEngine.configure(asset: AVURLAsset(url: url), audioMix: nil)
            otherEngine.meterPlayback(at: .zero)
            let otherID = try #require(otherEngine.pendingDecodeID)
            let otherTask = try #require(otherEngine.decodeTask)
            #expect(await registered.next() == otherID)
            await firstTask.value
            #expect(await decoder.pendingRequestID == otherID)
            #expect(meter.display().left.levelDb == AudioMeterChannelState.floorDb)
            #expect(otherMeter.display().left.levelDb == AudioMeterChannelState.floorDb)
            let retry = try #require(engine.decodeTask)
            engine.meterPlayback(at: .zero)
            #expect(engine.pendingDecodeID == firstID)
            if stop {
                engine.stopPlaybackMetering()
                await retry.value
                #expect(engine.pendingDecodeID == nil)
            }
            gate.signal()
            if !stop {
                #expect(await registered.next() != firstID)
                await retry.value
                if let retriedDecode = engine.decodeTask { await retriedDecode.value }
            }
            await otherTask.value
            #expect(engine.pendingDecodeID == nil)
            #expect(otherEngine.pendingDecodeID == nil)
            if stop {
                #expect(meter.display().left.levelDb == AudioMeterChannelState.floorDb)
            } else {
                #expect(meter.display().left.levelDb > AudioMeterChannelState.floorDb)
            }
            #expect(otherMeter.display().left.levelDb > AudioMeterChannelState.floorDb)
        } catch {
            try await Task.detached { try FileManager.default.removeItem(at: url) }.value
            throw error
        }
        try await Task.detached { try FileManager.default.removeItem(at: url) }.value
    }

    @Test func decodesStereoPCMAndReleasesSlotAfterFailure() async throws {
        let url = try await makeAudioFixture()
        do {
            let decoder = ScrubAudioDecoder()
            let missing = await decoder.decode(
                source: .init(asset: AVURLAsset(url: url.appendingPathExtension("missing")), audioMix: nil, generation: 0),
                startSample: 0, frameCount: 48
            )
            guard case .failure = missing else { throw CocoaError(.fileReadUnknown) }
            let result = await decoder.decode(
                source: .init(asset: AVURLAsset(url: url), audioMix: nil, generation: 1), startSample: 48, frameCount: 48
            )
            let window: ScrubAudioDecoder.PCMWindow
            switch result {
            case .success(let value): window = value
            default: throw CocoaError(.fileReadUnknown)
            }
            #expect(window.startSample == 48 && window.hasAudioTracks)
            #expect(window.left == Array(repeating: 16384, count: 48))
            #expect(window.right == Array(repeating: -8192, count: 48))
            let mixedSource = try await Task.detached {
                let asset = AVURLAsset(url: url)
                let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(0.5, at: .zero)
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                return ScrubAudioDecoder.Source(asset: asset, audioMix: mix, generation: 2)
            }.value
            let mixed = await decoder.decode(source: mixedSource, startSample: 48, frameCount: 48)
            guard case .success(let mixedWindow) = mixed else { throw CocoaError(.fileReadUnknown) }
            #expect(mixedWindow.left == Array(repeating: 8192, count: 48))
            #expect(mixedWindow.right == Array(repeating: -4096, count: 48))
            let silent = await decoder.decode(
                source: .init(asset: AVMutableComposition(), audioMix: nil, generation: 2), startSample: 0, frameCount: 48
            )
            guard case .success(let silence) = silent else { throw CocoaError(.fileReadUnknown) }
            #expect(!silence.hasAudioTracks && silence.left == Array(repeating: 0, count: 48))
        } catch {
            try await Task.detached { try FileManager.default.removeItem(at: url) }.value
            throw error
        }
        try await Task.detached { try FileManager.default.removeItem(at: url) }.value
    }
}

private func enqueue(
    _ decoder: ScrubAudioDecoder,
    read: @escaping ScrubAudioDecoder.Read
) async -> (id: UUID, results: AsyncStream<ScrubAudioDecoder.Outcome>) {
    let id = UUID()
    let results = AsyncStream<ScrubAudioDecoder.Outcome>.makeStream()
    await decoder.register(id: id, cancellation: .init(), prepare: { read }, completion: {
        results.continuation.yield($0)
        results.continuation.finish()
    })
    return (id, results.stream)
}

private func makeAudioFixture() async throws -> URL {
    try await Task.detached {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        let channels = try #require(pcm.floatChannelData)
        for index in 0..<480 {
            channels[0][index] = 0.5
            channels[1][index] = -0.25
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcm)
        return url
    }.value
}
