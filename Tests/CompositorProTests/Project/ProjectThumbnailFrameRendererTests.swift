import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class ThumbnailFrameProbe {
    let preparing = PackageTestSignal()
    let prepared = PackageTestSignal()
    let generating = PackageTestSignal()
    let cancelled = PackageTestSignal()
    var pausePreparation = false
    private(set) var prepareCalls = 0
    private(set) var generateCalls = 0
    private(set) var cancellationCalls = 0
    private(set) var preparationOnMain = false
    private(set) var generationOnMain = false
    private(set) var cancellationOnMain = false
    private(set) var completion: ProjectThumbnailFrameRenderer.Completion?

    func operations() -> ProjectThumbnailFrameRenderer.Operations {
        ProjectThumbnailFrameRenderer.Operations(
            prepare: { [self] _ in
                let onMain = Self.isMainThread()
                await prepare(onMain: onMain)
            },
            generate: { [self] _, completion in
                let onMain = Self.isMainThread()
                Task { await start(completion, onMain: onMain) }
            },
            cancel: { [self] _ in
                let onMain = Self.isMainThread()
                Task { await requestCancellation(onMain: onMain) }
            }
        )
    }

    nonisolated private static func isMainThread() -> Bool {
        Thread.isMainThread
    }

    private func prepare(onMain: Bool) async {
        prepareCalls += 1
        preparationOnMain = onMain
        preparing.signal()
        if pausePreparation { await prepared.wait() }
    }

    private func start(_ completion: @escaping ProjectThumbnailFrameRenderer.Completion, onMain: Bool) {
        self.completion = completion
        generationOnMain = onMain
        generateCalls += 1
        generating.signal()
    }

    private func requestCancellation(onMain: Bool) {
        cancellationOnMain = onMain
        cancellationCalls += 1
        cancelled.signal()
    }
}

@MainActor
@Suite("Project thumbnail frame lifecycle")
struct ProjectThumbnailFrameRendererTests {
    private func image(using io: ProjectPackageIO) async throws -> CGImage {
        try await io.perform {
            guard let context = CGContext(
                data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
            return image
        }
    }

    @Test func initializationDoesNotStartWorkAndZeroTimeRunsOffMain() async throws {
        try await withPackageTestFixture { fixture in
            let probe = ThumbnailFrameProbe()
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: .zero,
                maxPixelSize: 16, operations: probe.operations()
            )
            #expect(probe.prepareCalls == 0)
            let task = Task { try await renderer.render() }
            await probe.generating.wait()
            #expect(!probe.preparationOnMain)
            #expect(!probe.generationOnMain)
            let completion = try #require(probe.completion)
            await completion(.success(try await image(using: fixture.io)))
            let frame = try await task.value
            #expect(frame.width == 16)
            #expect(frame.height == 8)
        }
    }

    @Test(arguments: [0, -1, Int.max])
    func invalidPixelSizeDoesNotStartNativeWork(_ size: Int) async throws {
        try await withPackageTestFixture { fixture in
            let probe = ThumbnailFrameProbe()
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: .zero,
                maxPixelSize: size, operations: probe.operations()
            )
            await #expect(throws: ProjectThumbnailFrameRenderer.RenderError.invalidRequest) { try await renderer.render() }
            #expect(probe.prepareCalls == 0)
            #expect(probe.generateCalls == 0)
        }
    }

    @Test(arguments: [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 30)])
    func invalidSourceTimeDoesNotStartNativeWork(_ time: CMTime) async throws {
        try await withPackageTestFixture { fixture in
            let probe = ThumbnailFrameProbe()
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: time,
                maxPixelSize: 16, operations: probe.operations()
            )
            await #expect(throws: ProjectThumbnailFrameRenderer.RenderError.invalidRequest) { try await renderer.render() }
            #expect(probe.prepareCalls == 0)
        }
    }

    @Test func cancellationBeforeStartDoesNotCreateGenerator() async throws {
        try await withPackageTestFixture { fixture in
            let probe = ThumbnailFrameProbe()
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: .zero,
                maxPixelSize: 16, operations: probe.operations()
            )
            let admitted = PackageTestSignal()
            let task = Task {
                await admitted.wait()
                return try await renderer.render()
            }
            task.cancel()
            admitted.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(probe.prepareCalls == 0)
            #expect(probe.generateCalls == 0)
        }
    }

    @Test func cancellationDuringPreparationDoesNotSubmitFrameRequest() async throws {
        try await withPackageTestFixture { fixture in
            let probe = ThumbnailFrameProbe()
            probe.pausePreparation = true
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: .zero,
                maxPixelSize: 16, operations: probe.operations()
            )
            let task = Task { try await renderer.render() }
            await probe.preparing.wait()
            task.cancel()
            await probe.cancelled.wait()
            probe.prepared.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!probe.cancellationOnMain)
            #expect(probe.generateCalls == 0)
        }
    }

    @Test func cancellationWaitsForTerminalCallbackAndCoordinatorDrain() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let coordinator = document.editorViewModel.projectPackageCoordinator
            let probe = ThumbnailFrameProbe()
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: .zero,
                maxPixelSize: 16, operations: probe.operations()
            )
            var terminalFailure = false
            let task = coordinator.startMutation { _ in
                _ = try await renderer.render()
            } onFailure: { error in
                #expect(error is CancellationError)
                terminalFailure = true
            }
            await probe.generating.wait()
            coordinator.beginClosing()
            task.cancel()
            await probe.cancelled.wait()
            #expect(!probe.cancellationOnMain)
            #expect(!terminalFailure)
            #expect(!coordinator.canFinishClosing)
            let completion = try #require(probe.completion)
            await completion(.failure(AVError(.operationCancelled)))
            await coordinator.waitUntilIdle()
            #expect(terminalFailure)
            #expect(coordinator.canFinishClosing)
            #expect(probe.cancellationCalls == 1)
        }
    }

    @Test func successCallbackAfterCancellationStillReturnsCancellation() async throws {
        try await withPackageTestFixture { fixture in
            let probe = ThumbnailFrameProbe()
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: .zero,
                maxPixelSize: 16, operations: probe.operations()
            )
            let task = Task { try await renderer.render() }
            await probe.generating.wait()
            task.cancel()
            await probe.cancelled.wait()
            let completion = try #require(probe.completion)
            await completion(.success(try await image(using: fixture.io)))
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test func duplicateAndStaleCallbacksDoNotAffectAnotherRequest() async throws {
        try await withPackageTestFixture { fixture in
            let source = fixture.root.appendingPathComponent("source.mov")
            let firstProbe = ThumbnailFrameProbe()
            let first = ProjectThumbnailFrameRenderer(url: source, time: .zero, maxPixelSize: 16, operations: firstProbe.operations())
            let firstTask = Task { try await first.render() }
            await firstProbe.generating.wait()
            let firstCompletion = try #require(firstProbe.completion)
            let frame = try await image(using: fixture.io)
            await firstCompletion(.success(frame))
            _ = try await firstTask.value
            let secondProbe = ThumbnailFrameProbe()
            let second = ProjectThumbnailFrameRenderer(url: source, time: .zero, maxPixelSize: 16, operations: secondProbe.operations())
            let secondTask = Task { try await second.render() }
            await secondProbe.generating.wait()
            await firstCompletion(.failure(CocoaError(.fileReadCorruptFile)))
            await firstCompletion(.success(frame))
            let secondCompletion = try #require(secondProbe.completion)
            await secondCompletion(.success(frame))
            #expect(try await secondTask.value.width == 16)
            await #expect(throws: ProjectThumbnailFrameRenderer.RenderError.alreadyStarted) { try await first.render() }
            #expect(firstProbe.generateCalls == 1)
            #expect(secondProbe.generateCalls == 1)
        }
    }

    @Test func overlappingRenderRefusesWithoutCancellingOwnedFrame() async throws {
        try await withPackageTestFixture { fixture in
            let probe = ThumbnailFrameProbe()
            let renderer = ProjectThumbnailFrameRenderer(
                url: fixture.root.appendingPathComponent("source.mov"), time: .zero,
                maxPixelSize: 16, operations: probe.operations()
            )
            let first = Task { try await renderer.render() }
            await probe.generating.wait()
            let admitted = PackageTestSignal()
            let second = Task {
                await admitted.wait()
                return try await renderer.render()
            }
            second.cancel()
            admitted.signal()
            await #expect(throws: ProjectThumbnailFrameRenderer.RenderError.alreadyStarted) { try await second.value }
            let completion = try #require(probe.completion)
            await completion(.success(try await image(using: fixture.io)))
            #expect(try await first.value.width == 16)
            #expect(probe.cancellationCalls == 0)
            #expect(probe.generateCalls == 1)
        }
    }

    @Test func nativeFrameAtZeroPreservesAspectAndMaximumSize() async throws {
        try await withPackageTestFixture { fixture in
            let source = try await StoryboardTimingFixtures.video(in: fixture.root).url
            let renderer = ProjectThumbnailFrameRenderer(url: source, time: .zero, maxPixelSize: 16)
            let frame = try await renderer.render()
            #expect(frame.width > 0)
            #expect(frame.height > 0)
            #expect(max(frame.width, frame.height) <= 16)
            #expect(frame.width == frame.height)
        }
    }

    @Test func invalidNativeMediaReachesTerminalFailure() async throws {
        try await withPackageTestFixture { fixture in
            let source = try await fixture.stage(Data("invalid media".utf8))
            let renderer = ProjectThumbnailFrameRenderer(url: source, time: .zero, maxPixelSize: 16)
            await #expect(throws: (any Error).self) { try await renderer.render() }
            await #expect(throws: ProjectThumbnailFrameRenderer.RenderError.alreadyStarted) { try await renderer.render() }
        }
    }
}
