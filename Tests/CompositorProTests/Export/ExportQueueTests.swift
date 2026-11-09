import Foundation
import Testing
@testable import CompositorPro

@Suite("Export queue", .serialized)
@MainActor
struct ExportQueueTests {
    @Test func runsInFIFOOrder() async throws {
        let queue = ExportQueue()
        var events: [String] = []
        let first = try enqueue(queue, "first.mov") { _ in
            events.append("first-start")
            await Task.yield()
            events.append("first-finish")
        }
        let second = try enqueue(queue, "second.mov") { _ in
            events.append("second-start")
            events.append("second-finish")
        }

        #expect(first.started)
        #expect(!second.started)
        #expect(second.queuePosition == 1)
        #expect(await waitUntil { !queue.hasActivity })
        #expect(events == ["first-start", "first-finish", "second-start", "second-finish"])
    }

    @Test func completionWaitReturnsTerminalFailureAndCanBeRepeated() async throws {
        let queue = ExportQueue()
        let submission = try enqueue(queue, UUID().uuidString) { service in service.error = "decode failed" }
        let result = try await queue.waitForCompletion(submission.jobID)
        #expect(result.status == .failed)
        #expect(result.error == "decode failed")
        #expect(try await queue.waitForCompletion(submission.jobID).status == .failed)
    }

    @Test(arguments: [false, true])
    func cancelingWaitDoesNotCancelJob(afterRegistration: Bool) async throws {
        let queue = ExportQueue()
        let gate = AsyncSemaphore(value: 0)
        let submission = try enqueue(queue, UUID().uuidString) { service in
            try? await gate.wait()
            service.error = "finished independently"
        }
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            continuation.yield(())
            return try await queue.waitForCompletion(submission.jobID)
        }
        if afterRegistration {
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(queue.jobs.first?.status.isPending == true)
        await gate.signal()
        #expect(try await queue.waitForCompletion(submission.jobID).error == "finished independently")
    }

    @Test func cancelingPreparingJobAdvancesQueueWithoutRunningIt() async throws {
        let queue = ExportQueue()
        var firstRan = false
        var secondRan = false
        let first = try enqueue(queue, "active.mov") { _ in
            firstRan = true
            try? await Task.sleep(for: .seconds(30))
        }
        let second = try enqueue(queue, "next.mov") { _ in secondRan = true }

        queue.cancel(first.jobID)

        #expect(await waitUntil {
            queue.job(first.jobID)?.status == .canceled && queue.job(second.jobID)?.status == .failed
        })
        #expect(!firstRan)
        #expect(secondRan)
        #expect(queue.job(second.jobID)?.error == "Export produced no output.")
    }

    @Test func cancelingWaitingJobDoesNotRunIt() async throws {
        let queue = ExportQueue()
        var waitingRan = false
        let blocker = try enqueue(queue, "waiting-blocker.mov") { _ in
            try? await Task.sleep(for: .seconds(30))
        }
        let waiting = try enqueue(queue, "waiting.mov") { _ in waitingRan = true }

        queue.cancel(waiting.jobID)
        queue.cancel(blocker.jobID)

        #expect(queue.job(waiting.jobID)?.status == .canceled)
        #expect(await waitUntil { !queue.hasActivity })
        #expect(!waitingRan)
    }

    @Test func scopesHistoryByProject() async throws {
        let queue = ExportQueue()
        let first = try enqueue(queue, "project-first.xml", projectID: "project-a") { _ in }
        let second = try enqueue(queue, "project-second.xml", projectID: "project-b") { _ in }
        #expect(await waitUntil { !queue.hasActivity })
        #expect(queue.jobs(for: "project-a").map(\.id) == [first.jobID])
        #expect(queue.jobs(for: "project-b").map(\.id) == [second.jobID])

        queue.clearFinished(for: "project-a")

        #expect(queue.jobs(for: "project-a").isEmpty)
        #expect(queue.jobs(for: "project-b").map(\.id) == [second.jobID])

        let url = temporaryURL("stable-project.palmier")
        let firstEditor = EditorViewModel()
        let secondEditor = EditorViewModel()
        firstEditor.projectURL = url
        secondEditor.projectURL = url
        #expect(firstEditor.exportQueueProjectID == secondEditor.exportQueueProjectID)
    }

    @Test func recordsDeliveredSourceIdsAndSkipsFailures() async throws {
        let queue = ExportQueue()
        let manifest = MediaManifest(entries: [
            .init(id: "vid", name: "Clip", type: .video, source: .external(absolutePath: "/tmp/vid.mp4"),
                  duration: 5.0, importInput: .init(origin: .init(provider: "pixabay", assetId: "12345"))),
            .init(id: "local", name: "Local", type: .video, source: .external(absolutePath: "/tmp/local.mp4"), duration: 5.0),
        ])
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v", mediaRef: "vid", start: 0, duration: 30)]),
        ])
        let outputURL = temporaryURL("delivered.xml")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let submission = try queue.enqueueForTesting(outputURL: outputURL) { service in
            await service.export(timeline: timeline, resolver: resolver, format: .xml,
                                 resolution: .matchTimeline, outputURL: outputURL)
        }
        #expect(await waitUntil { queue.job(submission.jobID)?.status.isFinished == true })
        #expect(queue.job(submission.jobID)?.status == .completed)
        #expect(queue.job(submission.jobID)?.sourceIds == Set(["stock:pixabay:12345"]))

        let history = StockDeliveryHistory.load()
        #expect(history.entries.count == 1)
        #expect(history.entries[0].outputFilename == outputURL.lastPathComponent)
        #expect(history.usedSourceIds == Set(["stock:pixabay:12345"]))
    }

    @Test func failedExportDoesNotPolluteDeliveryHistory() async throws {
        let queue = ExportQueue()
        let manifest = MediaManifest(entries: [
            .init(id: "vid", name: "Clip", type: .video, source: .external(absolutePath: "/tmp/vid.mp4"),
                  duration: 5.0, importInput: .init(origin: .init(provider: "pixabay", assetId: "12345"))),
        ])
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v", mediaRef: "vid", start: 0, duration: 30)]),
        ])
        let outputURL = temporaryURL("failed.xml")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let submission = try queue.enqueueForTesting(outputURL: outputURL) { service in
            service.error = "decode failed"
        }
        #expect(await waitUntil { queue.job(submission.jobID)?.status.isFinished == true })
        #expect(queue.job(submission.jobID)?.status == .failed)
        #expect(queue.job(submission.jobID)?.sourceIds == Set(["stock:pixabay:12345"]))

        let history = StockDeliveryHistory.load()
        #expect(history.entries.isEmpty, "a failed delivery does not record used sources")
    }

    @Test func lateProgressAndCancellationKeepCommittedExportCompleted() async throws {
        let queue = ExportQueue()
        let outputURL = temporaryURL("late-cancel.xml")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        var jobID: UUID!
        var cancellationAccepted: Bool?
        var progressUpdate: ((Double) -> Void)?
        let submission = try queue.enqueueForTesting(outputURL: outputURL) { service in
            progressUpdate = service.onProgressChange
            await service.export(
                timeline: Fixtures.timeline(),
                resolver: MediaResolver(manifest: { MediaManifest() }, projectURL: { nil }),
                format: .xml,
                resolution: .matchTimeline,
                outputURL: outputURL
            )
            cancellationAccepted = queue.cancel(jobID)
        }
        jobID = submission.jobID

        #expect(await waitUntil { queue.job(jobID)?.status.isFinished == true })
        #expect(cancellationAccepted == false)
        #expect(queue.job(jobID)?.status == .completed)
        progressUpdate?(0.25)
        #expect(queue.job(jobID)?.progress == 1)
    }

    private func enqueue(
        _ queue: ExportQueue,
        _ name: String,
        projectID: String = "test-project",
        operation: @escaping @MainActor (ExportService) async -> Void
    ) throws -> ExportQueueSubmission {
        try queue.enqueueForTesting(outputURL: temporaryURL(name), projectID: projectID, operation: operation)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("export-queue-\(name)")
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private extension ExportQueue {
    func job(_ id: UUID) -> ExportJob? { jobs.first { $0.id == id } }
}
