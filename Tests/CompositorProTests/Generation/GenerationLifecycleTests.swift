import AppKit
import Combine
import Foundation
import MCP
import Testing
@testable import CompositorPro

@MainActor
private final class GenerationLifecycleGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor GenerationDownloadProbe {
    private(set) var requests: [URL] = []

    func record(_ url: URL) -> Int {
        requests.append(url)
        return requests.count
    }
}

@Suite("Generation download lifecycle", .serialized)
@MainActor
struct GenerationDownloadLifecycleTests {
    private let remoteURL = URL(string: "https://example.invalid/result.png")!

    @Test func queuedDownloadSurvivesNativeSaveAsAndPersistsReadyMedia() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let coordinator = editor.projectPackageCoordinator
            let asset = makeAsset(editor: editor)
            let originalURL = asset.url
            let bytes = try await MediaInputIdentityFixtures.imageData()
            let stage = try await fixture.stage(bytes)
            let probe = GenerationDownloadProbe()
            let service = GenerationService(downloadMedia: { url in
                _ = await probe.record(url)
                return .init(fileURL: stage, httpStatusCode: 200)
            })
            try await savePackageTestDocument(document)
            let destination = fixture.root.appendingPathComponent("Copy.palmier", isDirectory: true)
            var fence: ProjectPackageCoordinator.SaveLease?
            coordinator.enqueueSave { fence = $0 }
            let saved = PackageTestSignal()
            var saveError: Error?
            document.save(to: destination, ofType: VideoProject.typeIdentifier, for: .saveAsOperation) { error in
                saveError = error
                saved.signal()
            }
            let entered = GenerationLifecycleGate()
            var completions = 0
            let download = Task {
                entered.open()
                return await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor, onComplete: { _ in
                    completions += 1
                })
            }
            await entered.wait()
            #expect(await probe.requests.isEmpty)
            coordinator.finishSave(try #require(fence)) {}
            await saved.wait()
            #expect(saveError == nil)
            #expect(await download.value)
            #expect(document.fileURL == destination)
            #expect(editor.projectURL == destination)
            #expect(completions == 1)
            #expect(await probe.requests == [remoteURL])
            try await assertReady(asset, document: document, fixture: fixture, bytes: bytes)
            #expect(try await !fixture.exists(stage))
            #expect(try await !fixture.exists(originalURL))
            #expect(try await !fixture.exists(fixture.package.appendingPathComponent("media/\(asset.url.lastPathComponent)")))
            let original = try await fixture.readPackage()
            #expect(original.manifest?.entries.first?.generationStatus == "downloading")
        }
    }

    @Test(arguments: ["source", "job", "output", "object"], [false, true])
    func staleDownloadCannotOverwriteNewerState(change: String, afterAdmission: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let coordinator = editor.projectPackageCoordinator
            let asset = makeAsset(editor: editor)
            let originalURL = asset.url
            let stage = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
            let entered = GenerationLifecycleGate()
            let release = GenerationLifecycleGate()
            let probe = GenerationDownloadProbe()
            let service = GenerationService(downloadMedia: { url in
                _ = await probe.record(url)
                await entered.open()
                await release.wait()
                return .init(fileURL: stage, httpStatusCode: 200)
            })
            var fence: ProjectPackageCoordinator.SaveLease?
            if !afterAdmission { coordinator.enqueueSave { fence = $0 } }
            var completions = 0
            let download = Task {
                if !afterAdmission { entered.open() }
                return await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor, onComplete: { _ in
                    completions += 1
                })
            }
            await entered.wait()
            let current = supersede(asset, change: change, editor: editor, root: fixture.root)
            let manifest = editor.mediaManifest
            let currentURL = current.url
            let currentInput = current.generationInput
            let currentPendingURL = current.pendingDownloadURL
            if let fence { coordinator.finishSave(fence) {} }
            release.open()
            #expect(await !download.value)
            #expect(editor.mediaAssetsById[asset.id] === current)
            #expect(current.url == currentURL)
            #expect(current.generationInput == currentInput)
            #expect(current.pendingDownloadURL == currentPendingURL)
            #expect(current.generationStatus == .generating)
            #expect(editor.mediaManifest == manifest)
            #expect(completions == 0)
            #expect(await probe.requests.count == (afterAdmission ? 1 : 0))
            #expect(try await fixture.exists(stage) == !afterAdmission)
            #expect(try await !fixture.exists(originalURL))
            #expect(try await !fixture.exists(fixture.package))
        }
    }

    @Test(arguments: [false, true])
    func queuedAdmissionCancellationRetainsRetryLinkAndTerminalManifest(cancelTask: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let coordinator = editor.projectPackageCoordinator
            let asset = makeAsset(editor: editor)
            let probe = GenerationDownloadProbe()
            let service = GenerationService(downloadMedia: { url in
                _ = await probe.record(url)
                throw URLError(.unknown)
            })
            var fence: ProjectPackageCoordinator.SaveLease?
            coordinator.enqueueSave { fence = $0 }
            let entered = GenerationLifecycleGate()
            let download = Task {
                entered.open()
                return await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
            }
            await entered.wait()
            if cancelTask { download.cancel() }
            else { coordinator.beginClosing() }
            #expect(await !download.value)
            coordinator.finishSave(try #require(fence)) {}
            #expect(asset.generationStatus == .failed("Generation canceled."))
            #expect(asset.pendingDownloadURL == remoteURL)
            #expect(!asset.isGenerating)
            #expect(await probe.requests.isEmpty)
            if !cancelTask {
                #expect(throws: GenerationService.StartError.projectUnavailable) {
                    try service.retryDownload(asset: asset, editor: editor)
                }
            }
            try await savePackageTestDocument(document)
            let saved = try await fixture.readPackage()
            let entry = try #require(saved.manifest?.entries.first)
            #expect(entry.generationStatus == "failed: Generation canceled.")
            #expect(entry.generationInput?.backendJobId == "download-job")
            #expect(entry.generationInput?.resultURLs == [remoteURL.absoluteString])
            #expect(try await !fixture.exists(asset.url))
        }
    }

    @Test(arguments: ["cancellation", "http", "finalization"])
    func failedDownloadCanRetryWithoutPaidSubmission(failure: String) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let asset = makeAsset(editor: editor)
            let bytes = try await MediaInputIdentityFixtures.imageData()
            let rejectedStage = failure == "cancellation" ? nil : try await fixture.stage(Data("INVALID".utf8))
            let goodStage = try await fixture.stage(bytes)
            let probe = GenerationDownloadProbe()
            var submissions = 0
            let service = GenerationService(submitGeneration: { _, _, _ in
                submissions += 1
                return "unexpected"
            }, downloadMedia: { url in
                let count = await probe.record(url)
                if count == 1 {
                    if failure == "cancellation" { throw CancellationError() }
                    return .init(fileURL: try #require(rejectedStage), httpStatusCode: failure == "http" ? 503 : 200)
                }
                return .init(fileURL: goodStage, httpStatusCode: 200)
            })
            #expect(await !service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor))
            #expect(!Task.isCancelled)
            #expect(!asset.isGenerating)
            #expect(asset.pendingDownloadURL == remoteURL)
            if failure == "cancellation" {
                #expect(asset.generationStatus == .failed("Generation canceled."))
            } else if failure == "http" {
                #expect(asset.generationStatus == .failed(URLError(.badServerResponse).localizedDescription))
            } else if failure == "finalization" {
                #expect(asset.generationStatus == .failed("Could not read media file."))
                #expect(editor.unprocessableMediaRefs.contains(asset.id))
            }
            if let rejectedStage { #expect(try await !fixture.exists(rejectedStage)) }
            let ready = GenerationLifecycleGate()
            editor.onProjectCheckpointRequired = {
                if asset.generationStatus == .none { ready.open() }
            }
            try service.retryDownload(asset: asset, editor: editor)
            try service.retryDownload(asset: asset, editor: editor)
            await ready.wait()
            await service.suspendAndWait()
            #expect(await probe.requests == [remoteURL, remoteURL])
            #expect(submissions == 0)
            #expect(!editor.unprocessableMediaRefs.contains(asset.id))
            try await assertReady(asset, document: document, fixture: fixture, bytes: bytes)
            #expect(try await !fixture.exists(goodStage))
        }
    }

    @Test func canceledReturnedStageIsCleanedAndSettlesRetryExactlyOnce() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let asset = makeAsset(editor: editor)
            asset.generationStatus = .failed("Download interrupted")
            asset.pendingDownloadURL = remoteURL
            let stage = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
            let entered = GenerationLifecycleGate()
            let canceled = GenerationLifecycleGate()
            let release = GenerationLifecycleGate()
            let service = GenerationService(downloadMedia: { _ in
                await withTaskCancellationHandler {
                    await entered.open()
                    await release.wait()
                } onCancel: {
                    Task { @MainActor in canceled.open() }
                }
                return .init(fileURL: stage, httpStatusCode: 200)
            })
            var checkpoints = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            try service.retryDownload(asset: asset, editor: editor)
            await entered.wait()
            let saved = PackageTestSignal()
            var saveError: Error?
            document.save(to: fixture.package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                saveError = error
                saved.signal()
            }
            let suspension = Task { await service.suspendAndWait() }
            await canceled.wait()
            release.open()
            await suspension.value
            await saved.wait()
            #expect(saveError == nil)
            #expect(asset.generationStatus == .failed("Generation canceled."))
            #expect(asset.pendingDownloadURL == remoteURL)
            #expect(checkpoints == 1)
            #expect(try await !fixture.exists(stage))
            #expect(try await !fixture.exists(asset.url))
            let package = try await fixture.readPackage()
            #expect(package.manifest?.entries.first?.generationStatus == "failed: Generation canceled.")
            #expect(package.manifest?.entries.first?.generationInput?.resultURLs == [remoteURL.absoluteString])
            await service.suspendAndWait()
            #expect(checkpoints == 1)
        }
    }

    @Test func prestartRetryCancellationReleasesAttemptForReopenMonitoring() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let asset = makeAsset(editor: editor)
            asset.generationStatus = .failed("Download interrupted")
            asset.pendingDownloadURL = remoteURL
            let bytes = try await MediaInputIdentityFixtures.imageData()
            let stage = try await fixture.stage(bytes)
            let entered = GenerationLifecycleGate()
            let canceled = GenerationLifecycleGate()
            let release = GenerationLifecycleGate()
            let ready = GenerationLifecycleGate()
            let probe = GenerationDownloadProbe()
            var submissions = 0
            var subscriptions: [String] = []
            let service = GenerationService(beforeTaskStart: {
                await withTaskCancellationHandler {
                    entered.open()
                    await release.wait()
                } onCancel: {
                    Task { @MainActor in canceled.open() }
                }
            }, submitGeneration: { _, _, _ in
                submissions += 1
                return "unexpected"
            }, subscribe: { id in
                subscriptions.append(id)
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }, downloadMedia: { url in
                _ = await probe.record(url)
                return .init(fileURL: stage, httpStatusCode: 200)
            })
            var checkpoints = 0
            editor.onProjectCheckpointRequired = {
                checkpoints += 1
                if asset.generationStatus == .none { ready.open() }
            }
            try service.retryDownload(asset: asset, editor: editor)
            try service.retryDownload(asset: asset, editor: editor)
            await entered.wait()
            let suspension = Task { await service.suspendAndWait() }
            await canceled.wait()
            release.open()
            await suspension.value
            #expect(asset.generationStatus == .failed("Generation canceled."))
            #expect(asset.pendingDownloadURL == remoteURL)
            #expect(checkpoints == 1)
            #expect(await probe.requests.isEmpty)
            #expect(throws: GenerationService.StartError.suspended) { try service.retryDownload(asset: asset, editor: editor) }
            service.resumePendingGenerations(editor: editor)
            await ready.wait()
            await service.suspendAndWait()
            #expect(submissions == 0)
            #expect(subscriptions == ["download-job"])
            #expect(await probe.requests == [remoteURL])
            try await assertReady(asset, document: document, fixture: fixture, bytes: bytes)
            #expect(try await !fixture.exists(stage))
        }
    }

    @Test(arguments: ["source", "job", "output", "object"])
    func prestartRetryCancellationCannotOverwriteSupersededState(change: String) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let asset = makeAsset(editor: editor)
            asset.generationStatus = .failed("Download interrupted")
            asset.pendingDownloadURL = remoteURL
            let entered = GenerationLifecycleGate()
            let canceled = GenerationLifecycleGate()
            let release = GenerationLifecycleGate()
            let probe = GenerationDownloadProbe()
            let service = GenerationService(beforeTaskStart: {
                await withTaskCancellationHandler {
                    entered.open()
                    await release.wait()
                } onCancel: {
                    Task { @MainActor in canceled.open() }
                }
            }, downloadMedia: { url in
                _ = await probe.record(url)
                throw URLError(.unknown)
            })
            var checkpoints = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            try service.retryDownload(asset: asset, editor: editor)
            await entered.wait()
            let current = supersede(asset, change: change, editor: editor, root: fixture.root)
            let manifest = editor.mediaManifest
            let sourceURL = current.url
            let input = current.generationInput
            let pendingURL = current.pendingDownloadURL
            let suspension = Task { await service.suspendAndWait() }
            await canceled.wait()
            release.open()
            await suspension.value
            #expect(editor.mediaAssetsById[asset.id] === current)
            #expect(current.url == sourceURL)
            #expect(current.generationInput == input)
            #expect(current.pendingDownloadURL == pendingURL)
            #expect(current.generationStatus == .generating)
            #expect(editor.mediaManifest == manifest)
            #expect(checkpoints == 0)
            #expect(await probe.requests.isEmpty)
            #expect(try await !fixture.exists(fixture.package))
        }
    }

    private func makeAsset(editor: EditorViewModel) -> MediaAsset {
        var input = GenerationInput(prompt: "Fixture", model: "fixture", duration: 0, aspectRatio: "16:9")
        input.backendJobId = "download-job"
        input.outputIndex = 0
        input.resultURLs = [remoteURL.absoluteString]
        let asset = MediaAsset(
            url: editor.projectURL!.appendingPathComponent("media/placeholder.png"),
            type: .image, name: "Fixture", duration: 5, generationInput: input
        )
        asset.generationStatus = .downloading
        editor.importMediaAsset(asset)
        return asset
    }

    private func supersede(_ asset: MediaAsset, change: String, editor: EditorViewModel, root: URL) -> MediaAsset {
        let current: MediaAsset
        if change == "object" {
            current = MediaAsset(id: asset.id, url: asset.url, type: .image, name: "Replacement", generationInput: asset.generationInput)
            editor.mediaAssets = [current]
        } else {
            current = asset
            switch change {
            case "source": current.url = root.appendingPathComponent("replacement.png")
            case "job": current.generationInput?.backendJobId = "replacement-job"
            case "output": current.generationInput?.outputIndex = 1
            default: Issue.record("Unknown fixture change")
            }
        }
        current.generationStatus = .generating
        current.pendingDownloadURL = URL(string: "https://example.invalid/replacement.png")!
        editor.updateManifestMetadata(for: [current])
        return current
    }

    private func assertReady(
        _ asset: MediaAsset, document: VideoProject, fixture: PackageTestFixture, bytes: Data
    ) async throws {
        #expect(asset.generationStatus == .none)
        #expect(!asset.isGenerating)
        #expect(asset.pendingDownloadURL == nil)
        #expect(asset.inputIdentity != nil)
        #expect(asset.sourceWidth == 2)
        #expect(asset.sourceHeight == 2)
        let package = try #require(document.fileURL)
        #expect(asset.url.deletingLastPathComponent() == package.appendingPathComponent("media", isDirectory: true))
        #expect(try await fixture.contents(of: asset.url) == bytes)
        try await savePackageTestDocument(document)
        let saved = try await fixture.readPackage(at: package)
        let entry = try #require(saved.manifest?.entries.first(where: { $0.id == asset.id }))
        #expect(entry.source == .project(relativePath: "media/\(asset.url.lastPathComponent)"))
        #expect(entry.generationStatus == nil)
        #expect(entry.generationInput?.backendJobId == "download-job")
        #expect(entry.generationInput?.outputIndex == 0)
        #expect(entry.generationInput?.resultURLs == [remoteURL.absoluteString])
        #expect(entry.inputIdentity == asset.inputIdentity)
        #expect(MediaAsset(entry: entry, resolvedURL: asset.url).generationStatus == .none)
    }
}

@Suite("Generation lifecycle")
@MainActor
struct GenerationLifecycleTests {
    @Test(arguments: ["closing", "closed", "suspended"])
    func refusalPreservesInventoryManifestAndUndo(state: String) async throws {
        let editor = EditorViewModel()
        let service = GenerationService()
        let draft = makeDraft(editor: editor)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undo.attach(undo)
        if state == "suspended" {
            await service.suspendAndWait()
        } else {
            let lease = try #require(editor.projectPackageCoordinator.beginClosing())
            if state == "closed" { try editor.projectPackageCoordinator.finishClosing(lease) }
        }
        let ids = editor.mediaAssets.map(\.id)
        let manifest = editor.mediaManifest
        let timeline = editor.timeline
        let expected: GenerationService.StartError = state == "suspended" ? .suspended : .projectUnavailable
        #expect(throws: expected) { try start(service: service, editor: editor) }
        #expect(throws: expected) { try service.enhanceDraft(asset: draft, editor: editor) }
        #expect(editor.mediaAssets.map(\.id) == ids)
        #expect(editor.mediaManifest == manifest)
        #expect(editor.timeline == timeline)
        #expect(!undo.canUndo)
        #expect(undo.groupingLevel == 0)
    }

    @Test func canceledCallerCannotCreatePlaceholders() async {
        let editor = EditorViewModel()
        let service = GenerationService()
        let caller = Task { try start(service: service, editor: editor) }
        caller.cancel()
        await #expect(throws: GenerationService.StartError.canceled) { try await caller.value }
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.mediaManifest.entries.isEmpty)
    }

    @Test func prestartCancellationSettlesOnceAndReopenNeverResubmits() async throws {
        let editor = EditorViewModel()
        let entered = GenerationLifecycleGate()
        let canceled = GenerationLifecycleGate()
        let release = GenerationLifecycleGate()
        var submissions = 0
        var failures = 0
        let service = GenerationService(beforeTaskStart: {
            await withTaskCancellationHandler {
                entered.open()
                await release.wait()
            } onCancel: {
                Task { @MainActor in canceled.open() }
            }
        }, submitGeneration: { _, _, _ in
            submissions += 1
            return "unexpected"
        })
        let id = try start(service: service, editor: editor, onFailure: { failures += 1 })
        await entered.wait()
        let suspension = Task { await service.suspendAndWait() }
        await canceled.wait()
        #expect(throws: GenerationService.StartError.suspended) { try start(service: service, editor: editor) }
        service.resumePendingGenerations(editor: editor)
        #expect(throws: GenerationService.StartError.suspended) { try service.requireAvailable(editor: editor) }
        release.open()
        await suspension.value
        let asset = try #require(editor.mediaAssetsById[id])
        #expect(asset.generationStatus == .failed("Generation canceled."))
        #expect(editor.mediaManifest.entries.first?.generationStatus == "failed: Generation canceled.")
        #expect(failures == 1)
        #expect(submissions == 0)
        await service.suspendAndWait()
        service.resumePendingGenerations(editor: editor)
        try service.requireAvailable(editor: editor)
        #expect(failures == 1)
        #expect(submissions == 0)
    }

    @Test func cancellationAfterAcknowledgmentRetainsJobAndOnlyResumesMonitoring() async throws {
        let editor = EditorViewModel()
        let submitted = GenerationLifecycleGate()
        let canceled = GenerationLifecycleGate()
        let acknowledgment = GenerationLifecycleGate()
        let monitored = GenerationLifecycleGate()
        var submissions = 0
        var subscriptions: [String] = []
        var failures = 0
        let service = GenerationService(submitGeneration: { _, _, _ in
            submissions += 1
            await withTaskCancellationHandler {
                submitted.open()
                await acknowledgment.wait()
            } onCancel: {
                Task { @MainActor in canceled.open() }
            }
            return "retained-job"
        }, subscribe: { id in
            subscriptions.append(id)
            monitored.open()
            return nil
        })
        let id = try start(service: service, editor: editor, onFailure: { failures += 1 })
        await submitted.wait()
        let suspension = Task { await service.suspendAndWait() }
        await canceled.wait()
        acknowledgment.open()
        await suspension.value
        let asset = try #require(editor.mediaAssetsById[id])
        #expect(asset.generationInput?.backendJobId == "retained-job")
        #expect(editor.mediaManifest.entries.first?.generationInput?.backendJobId == "retained-job")
        #expect(asset.generationStatus == .failed("Generation canceled."))
        #expect(failures == 1)
        service.resumePendingGenerations(editor: editor)
        service.resumePendingGenerations(editor: editor)
        await monitored.wait()
        await service.suspendAndWait()
        #expect(subscriptions == ["retained-job"])
        #expect(submissions == 1)
        #expect(failures == 1)
    }

    @Test func enhancementCanceledBeforeStartSettlesOnceWithoutSubmitting() async throws {
        let editor = EditorViewModel()
        let draft = makeDraft(editor: editor)
        let entered = GenerationLifecycleGate()
        let canceled = GenerationLifecycleGate()
        let release = GenerationLifecycleGate()
        var checkpoints = 0
        editor.onProjectCheckpointRequired = { checkpoints += 1 }
        let service = GenerationService(beforeTaskStart: {
            await withTaskCancellationHandler {
                entered.open()
                await release.wait()
            } onCancel: {
                Task { @MainActor in canceled.open() }
            }
        })
        let id = try service.enhanceDraft(asset: draft, editor: editor)
        await entered.wait()
        let suspension = Task { await service.suspendAndWait() }
        await canceled.wait()
        release.open()
        await suspension.value
        let placeholder = try #require(editor.mediaAssetsById[id])
        #expect(placeholder.generationStatus == .failed("Generation canceled."))
        #expect(placeholder.generationInput?.backendJobId == nil)
        #expect(draft.generationInput?.backendJobId == "draft-job")
        #expect(editor.mediaPanelToast?.message == L10n.string("Generation canceled."))
        #expect(checkpoints == 1)
        await service.suspendAndWait()
        #expect(checkpoints == 1)
    }

    @Test func invalidDraftRefusesWithoutImport() throws {
        let editor = EditorViewModel()
        let service = GenerationService()
        let draft = makeDraft(editor: editor)
        draft.generationInput?.backendJobId = ""
        let manifest = editor.mediaManifest
        #expect(throws: GenerationService.StartError.invalidDraft) { try service.enhanceDraft(asset: draft, editor: editor) }
        #expect(editor.mediaAssets.count == 1)
        #expect(editor.mediaManifest == manifest)
    }

    @Test func interruptedMonitorSettlesOnceWithoutDroppingJobIdentity() async throws {
        let editor = EditorViewModel()
        let settled = GenerationLifecycleGate()
        var failures = 0
        let service = GenerationService(submitGeneration: { _, _, _ in "retained-job" }, subscribe: { _ in
            Empty(completeImmediately: true).eraseToAnyPublisher()
        })
        let id = try start(service: service, editor: editor, onFailure: {
            failures += 1
            settled.open()
        })
        await settled.wait()
        await service.suspendAndWait()
        let asset = try #require(editor.mediaAssetsById[id])
        #expect(asset.generationStatus == .failed("Generation monitoring interrupted."))
        #expect(asset.generationInput?.backendJobId == "retained-job")
        #expect(failures == 1)
    }

    @Test func monitorCannotOverwriteRetargetedJobAfterAwait() async throws {
        let editor = EditorViewModel()
        let settled = GenerationLifecycleGate()
        let service = GenerationService(submitGeneration: { _, _, _ in "original-job" }, subscribe: { _ in
            editor.mediaAssets.first?.generationInput?.backendJobId = "replacement-job"
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        })
        let id = try start(service: service, editor: editor, onFailure: { settled.open() })
        await settled.wait()
        await service.suspendAndWait()
        let asset = try #require(editor.mediaAssetsById[id])
        #expect(asset.generationInput?.backendJobId == "replacement-job")
        #expect(asset.generationStatus == .generating)
    }

    @Test func unacknowledgedSubmissionFailureNeverRetriesOnReopen() async throws {
        let editor = EditorViewModel()
        let settled = GenerationLifecycleGate()
        var submissions = 0
        let service = GenerationService(submitGeneration: { _, _, _ in
            submissions += 1
            throw URLError(.networkConnectionLost)
        })
        let id = try start(service: service, editor: editor, onFailure: { settled.open() })
        await settled.wait()
        await service.suspendAndWait()
        service.resumePendingGenerations(editor: editor)
        let asset = try #require(editor.mediaAssetsById[id])
        #expect(asset.generationInput?.backendJobId == nil)
        #expect(!asset.isGenerating)
        #expect(submissions == 1)
    }

    @Test func changedReferenceBeforeOwnedTaskStartsCannotSubmitPaidWork() async throws {
        let editor = EditorViewModel()
        let reference = MediaAsset(url: URL(fileURLWithPath: "/fixture/original.png"), type: .image, name: "Fixture")
        editor.importMediaAsset(reference)
        let entered = GenerationLifecycleGate()
        let release = GenerationLifecycleGate()
        let failed = GenerationLifecycleGate()
        var submissions = 0
        let service = GenerationService(beforeTaskStart: {
            entered.open()
            await release.wait()
        }, submitGeneration: { _, _, _ in
            submissions += 1
            return "unexpected"
        }, subscribe: { _ in nil })
        let id = try start(service: service, editor: editor, references: [reference], onFailure: { failed.open() })
        await entered.wait()
        reference.url = URL(fileURLWithPath: "/fixture/replacement.png")
        release.open()
        await failed.wait()
        await service.suspendAndWait()
        let placeholder = try #require(editor.mediaAssetsById[id])
        #expect(placeholder.generationStatus == .failed("generation_preparation_changed"))
        #expect(placeholder.generationInput?.backendJobId == nil)
        #expect(submissions == 0)
        #expect(GenerationService.localizedFailureMessage("generation_preparation_changed") == L10n.string("Generation inputs changed. Submit again."))
    }

    @Test func closedProjectRefusesGenerationThroughMCPWithoutSuccessIDs() async throws {
        let harness = ToolHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let lease = try #require(harness.editor.projectPackageCoordinator.beginClosing())
        try harness.editor.projectPackageCoordinator.finishClosing(lease)
        let server = Server(name: "generation-lifecycle", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "generation-lifecycle-tests", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            for name in ["generate_image", "generate_video", "generate_audio"] {
                let result = try await client.callTool(name: name, arguments: ["prompt": .string("Fixture")])
                #expect(result.isError == true)
                let content = try #require(result.content.first)
                guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
                #expect(text == "project_unavailable")
                #expect(!text.contains("Placeholder asset ID"))
            }
            let readback = try await client.callTool(name: "get_media")
            #expect(readback.isError == true)
            let content = try #require(readback.content.first)
            guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
            #expect(text == "project_unavailable")
            #expect(harness.editor.mediaAssets.isEmpty)
            #expect(harness.editor.mediaManifest.entries.isEmpty)
            #expect(!undo.canUndo)
            #expect(undo.groupingLevel == 0)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func start(
        service: GenerationService, editor: EditorViewModel, references: [MediaAsset] = [],
        onFailure: (@MainActor () -> Void)? = nil
    ) throws -> String {
        try service.generate(
            genInput: GenerationInput(prompt: "Fixture", model: "fixture", duration: 0, aspectRatio: "16:9"),
            assetType: .image,
            placeholderDuration: 5,
            references: references,
            preUploadedURLs: references.isEmpty ? nil : ["https://example.invalid/reference.png"],
            buildParams: { _ in
                .image(ImageGenerationParams(
                    prompt: "Fixture", aspectRatio: "16:9", resolution: nil, quality: nil, imageURLs: [], numImages: 1
                ))
            },
            fileExtension: "png",
            projectURL: nil,
            editor: editor,
            onFailure: onFailure
        )
    }

    private func makeDraft(editor: EditorViewModel) -> MediaAsset {
        var input = GenerationInput(prompt: "Fixture", model: "fixture", duration: 5, aspectRatio: "16:9")
        input.draft = true
        input.backendJobId = "draft-job"
        input.resultURLs = ["https://example.invalid/draft.mp4", "https://example.invalid/enhanced.mp4"]
        let draft = MediaAsset(url: URL(fileURLWithPath: "/fixture/draft.mp4"), type: .video, name: "Fixture", generationInput: input)
        editor.importMediaAsset(draft)
        return draft
    }
}
