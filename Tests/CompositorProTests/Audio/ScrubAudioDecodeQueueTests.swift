import Testing
@testable import CompositorPro

@MainActor
@Suite("Scrub audio decode queue")
struct ScrubAudioDecodeQueueTests {
    @Test func replacementWaitsForTeardownAndKeepsOnlyLatestRequest() async {
        let queue = ScrubAudioDecodeQueue()
        let active = ControlledScrubDecode()
        let finished = ScrubDecodeCompletion()
        var events: [String] = []

        queue.submit {
            events.append("active")
            await active.run()
            events.append("teardown")
            if !Task.isCancelled { events.append("stale publication") }
        }
        await active.waitUntilStarted()

        queue.submit { events.append("superseded") }
        queue.submit {
            events.append("latest")
            finished.signal()
        }

        #expect(queue.hasWork)
        #expect(events == ["active"])
        active.finish()
        await finished.wait()

        #expect(active.wasCancelled)
        #expect(events == ["active", "teardown", "latest"])
    }

    @Test func cancellationDiscardsPendingWorkUntilActiveTeardownFinishes() async {
        let queue = ScrubAudioDecodeQueue()
        let active = ControlledScrubDecode()
        let finished = ScrubDecodeCompletion()
        let restarted = ScrubDecodeCompletion()
        var pendingRan = false

        queue.submit {
            await active.run()
            finished.signal()
        }
        await active.waitUntilStarted()
        queue.submit { pendingRan = true }
        queue.cancel()

        #expect(queue.hasWork)
        active.finish()
        await finished.wait()

        #expect(active.wasCancelled)
        #expect(!pendingRan)
        queue.submit { restarted.signal() }
        await restarted.wait()
    }

    @Test func newSessionWaitsForCancelledSessionTeardown() async {
        let queue = ScrubAudioDecodeQueue()
        let active = ControlledScrubDecode()
        let newSession = ScrubDecodeCompletion()
        var starts: [Int] = []

        queue.submit {
            starts.append(1)
            await active.run()
        }
        await active.waitUntilStarted()
        queue.submit { starts.append(2) }
        queue.cancel()
        queue.submit {
            starts.append(3)
            newSession.signal()
        }

        #expect(starts == [1])
        active.finish()
        await newSession.wait()
        #expect(starts == [1, 3])
        #expect(active.wasCancelled)
    }

    @Test func teardownCancelsActiveTaskAndDropsItsReplacement() async {
        var queue: ScrubAudioDecodeQueue? = ScrubAudioDecodeQueue()
        let active = ControlledScrubDecode()
        let finished = ScrubDecodeCompletion()
        var replacementRan = false

        queue?.submit {
            await active.run()
            finished.signal()
        }
        await active.waitUntilStarted()
        queue?.submit { replacementRan = true }
        queue = nil
        active.finish()
        await finished.wait()

        #expect(active.wasCancelled)
        #expect(!replacementRan)
    }

    @Test(arguments: [false, true])
    func readerLoopKeepsItsSerialExecutorThroughSuspensionAndCancellation(cancel: Bool) async throws {
        let suspendedRead = ControlledScrubDecode()
        let reader = ScrubReaderExecutorProbe()
        let task = Task { try await reader.run(suspendedRead: suspendedRead) }

        await suspendedRead.waitUntilStarted()
        if cancel { task.cancel() }
        suspendedRead.finish()
        let phases = try await task.value

        #expect(phases == (cancel
            ? ["next", "resumed", "snapshot", "teardown"]
            : ["next", "resumed", "process", "next", "snapshot", "teardown"]))
    }
}

private actor ScrubReaderExecutorProbe {
    nonisolated private let executor = ScrubAudioReaderExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func run(suspendedRead: ControlledScrubDecode) async throws -> [String] {
        var phases: [String] = []
        var readCount = 0
        _ = try await ScrubAudioReaderLoop.run(
            next: { () async -> Int? in
                self.executor.checkIsolated()
                phases.append("next")
                guard readCount == 0 else { return nil }
                readCount += 1
                await suspendedRead.run()
                self.executor.checkIsolated()
                phases.append("resumed")
                return 1
            },
            process: { _ in
                self.executor.checkIsolated()
                phases.append("process")
            },
            snapshot: {
                self.executor.checkIsolated()
                phases.append("snapshot")
            },
            teardown: {
                self.executor.checkIsolated()
                phases.append("teardown")
            }
        )
        return phases
    }
}

@MainActor
private final class ControlledScrubDecode {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    func run() async {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { completion = $0 }
        wasCancelled = Task.isCancelled
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish() {
        completion?.resume()
        completion = nil
    }
}

@MainActor
private final class ScrubDecodeCompletion {
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        finished = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
