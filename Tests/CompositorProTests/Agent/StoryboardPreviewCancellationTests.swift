import Foundation
import Testing
@testable import CompositorPro

@Suite("Storyboard preview cancellation")
struct StoryboardPreviewCancellationTests {
    enum Checkpoint: Sendable, CaseIterable {
        case admitted, beforeExport, exported

        func matches(_ phase: StoryboardPreviewRenderPhase) -> Bool {
            switch (self, phase) {
            case (.admitted, .admitted), (.beforeExport, .beforeExport), (.exported, .exported): true
            default: false
            }
        }
    }

    @Test(arguments: Checkpoint.allCases)
    func cancellationRemovesOwnedOutputAndReleasesPermit(checkpoint: Checkpoint) async throws {
        try await Self.withFixture { snapshot, _ in
            let gate = PreviewRenderCheckpoint()
            let task = Task {
                try await gate.run {
                    try await StoryboardPreviewService.render(snapshot, observe: { phase in
                        guard checkpoint.matches(phase) else { return }
                        let url: URL?
                        switch phase {
                        case .admitted: url = nil
                        case .beforeExport(let output), .exported(let output): url = output
                        }
                        await gate.hold(url: url)
                    })
                }
            }
            let output = await gate.waitUntilHeld()
            #expect(await gate.reachedCheckpoint)
            if checkpoint == .exported, let output { #expect(await Self.exists(output)) }
            task.cancel()
            await gate.release()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            if let output { #expect(await Self.exists(output) == false) }
            let retry = try await StoryboardPreviewService.render(snapshot)
            try await StoryboardPreviewService.remove(retry)
        }
    }

    @Test func changedSourceAfterExportRejectsAndRemovesOutput() async throws {
        try await Self.withFixture { snapshot, source in
            let gate = PreviewRenderCheckpoint()
            let task = Task {
                try await gate.run {
                    try await StoryboardPreviewService.render(snapshot, observe: { phase in
                        guard case .exported(let output) = phase else { return }
                        await gate.hold(url: output)
                    })
                }
            }
            let output = try #require(await gate.waitUntilHeld())
            #expect(await Self.exists(output))
            do { try await Self.changeBytes(source) }
            catch {
                await gate.release()
                _ = await task.result
                throw error
            }
            await gate.release()
            await #expect(throws: StoryboardPreviewError.sourceMismatch) { _ = try await task.value }
            #expect(await Self.exists(output) == false)
        }
    }

    @concurrent private static func withFixture(
        _ operation: @Sendable (StoryboardPreviewSnapshot, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let video = try await StoryboardTimingFixtures.video(in: directory)
            let identity = try await MediaInputIdentityService.shared.identify(video.url, force: true)
            var manifest = MediaManifest()
            manifest.entries = [.init(id: "source", name: "Source", type: .video,
                source: .external(absolutePath: video.url.path), duration: video.duration, inputIdentity: identity)]
            let plan = EditPlan(id: "preview", name: "Preview", timelineId: "timeline", fps: 30, width: 32, height: 32,
                shots: [.init(id: "scene", title: "Scene", startFrame: 0, endFrame: 30, mediaRef: "source")])
            let snapshot = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
            try await operation(snapshot, video.url)
            try FileManager.default.removeItem(at: directory)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @concurrent private static func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent private static func changeBytes(_ url: URL) async throws {
        let file = try FileHandle(forWritingTo: url)
        do {
            try file.seekToEnd()
            try file.write(contentsOf: Data([1, 2, 3]))
            try file.close()
        } catch {
            try file.close()
            throw error
        }
    }
}

private actor PreviewRenderCheckpoint {
    private(set) var reachedCheckpoint = false
    private var held = false
    private var url: URL?
    private var waiters: [CheckedContinuation<URL?, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func hold(url: URL?) async {
        await withCheckedContinuation {
            continuation = $0
            self.url = url
            held = true
            reachedCheckpoint = true
            waiters.forEach { $0.resume(returning: url) }
            waiters.removeAll()
        }
    }

    func run(_ operation: @Sendable () async throws -> StoryboardPreviewResult) async throws -> StoryboardPreviewResult {
        do {
            let result = try await operation()
            finish()
            return result
        } catch {
            finish()
            throw error
        }
    }

    private func finish() {
        held = true
        waiters.forEach { $0.resume(returning: nil) }
        waiters.removeAll()
    }

    func waitUntilHeld() async -> URL? {
        if held { return url }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
