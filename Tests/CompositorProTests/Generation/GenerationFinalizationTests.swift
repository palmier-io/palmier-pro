import AppKit
import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class FinalizationGate {
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
        for waiter in pending { waiter.resume() }
    }
}

@Suite("Generation finalization")
@MainActor
struct GenerationFinalizationTests {
    private let remoteURL = URL(string: "https://example.invalid/result.png")!

    @Test(arguments: ["metadata", "metadataFailure", "metadataCanceled", "identity", "identityFailure", "identityCanceled"],
          ["job", "output", "status", "import", "source", "sourceABA", "object", "cancel"])
    func staleFinalizationPreservesAssetAndManifest(boundary: String, change: String) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let source = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
            let asset = makeAsset(url: source, editor: editor)
            let metadata = try await MediaAssetMetadata.load(.init(url: source, type: .image, thumbnailMaxPixelSize: 32))
            let identity = try await MediaInputIdentityService().identify(source)
            let entered = FinalizationGate()
            let release = FinalizationGate()
            let task = Task {
                await editor.finalizeImportedAsset(asset, loadMetadata: { _ in
                    if boundary.hasPrefix("metadata") {
                        await entered.open()
                        await release.wait()
                        if boundary == "metadataFailure" { return .init(isReadable: false, duration: 5) }
                        if boundary == "metadataCanceled" { throw CancellationError() }
                    }
                    return metadata
                }, identify: { _ in
                    if boundary.hasPrefix("identity") {
                        await entered.open()
                        await release.wait()
                        if boundary == "identityFailure" { throw CocoaError(.fileReadCorruptFile) }
                        if boundary == "identityCanceled" { throw CancellationError() }
                    }
                    return identity
                })
            }
            await entered.wait()
            let current = retarget(asset, change: change, editor: editor, root: fixture.root)
            if change == "cancel" { task.cancel() }
            let oldState = AssetState(asset, projectURL: fixture.package)
            let currentState = AssetState(current, projectURL: fixture.package)
            let manifest = editor.mediaManifest
            let missing = editor.missingMediaRefs
            let unprocessable = editor.unprocessableMediaRefs
            let offline = editor.offlineMediaRefs
            release.open()
            #expect(await !task.value)
            #expect(editor.mediaAssetsById[asset.id] === current)
            oldState.expectUnchanged(asset, projectURL: fixture.package)
            currentState.expectUnchanged(current, projectURL: fixture.package)
            #expect(editor.mediaManifest == manifest)
            #expect(editor.missingMediaRefs == missing)
            #expect(editor.unprocessableMediaRefs == unprocessable)
            #expect(editor.offlineMediaRefs == offline)
        }
    }

    @Test(arguments: ["metadata", "identity"])
    func syntheticCancellationWithoutRetargetDoesNotPublishFailure(boundary: String) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let source = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
            let asset = makeAsset(url: source, editor: editor)
            let entered = FinalizationGate()
            let release = FinalizationGate()
            let task = Task {
                await editor.finalizeImportedAsset(asset, loadMetadata: { _ in
                    if boundary == "metadata" {
                        await entered.open()
                        await release.wait()
                        throw CancellationError()
                    }
                    return .init(isReadable: true, duration: 5, width: 2, height: 2)
                }, identify: { _ in
                    await entered.open()
                    await release.wait()
                    throw CancellationError()
                })
            }
            await entered.wait()
            let state = AssetState(asset, projectURL: fixture.package)
            let manifest = editor.mediaManifest
            release.open()
            #expect(await !task.value)
            #expect(!Task.isCancelled)
            state.expectUnchanged(asset, projectURL: fixture.package)
            #expect(editor.mediaManifest == manifest)
        }
    }

    @Test(arguments: ["metadata", "library", "preview"],
          ["job", "output", "status", "import", "source", "sourceABA", "cancel"])
    func metadataAndThumbnailsRejectChangedContext(path: String, change: String) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let source = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
            let asset = makeAsset(url: source, editor: editor)
            let metadata = try await MediaAssetMetadata.load(.init(url: source, type: .image, thumbnailMaxPixelSize: 32))
            let entered = FinalizationGate()
            let release = FinalizationGate()
            let load: MediaAssetMetadata.Loader = { _ in
                await entered.open()
                await release.wait()
                return metadata
            }
            let task = Task {
                switch path {
                case "metadata": #expect(await !asset.loadMetadata(load: load))
                case "library": await asset.loadLibraryThumbnail(load: load)
                case "preview": await asset.loadPreviewThumbnail(load: load)
                default: Issue.record("Unknown metadata path")
                }
            }
            await entered.wait()
            _ = retarget(asset, change: change, editor: editor, root: fixture.root)
            if change == "cancel" { task.cancel() }
            let state = AssetState(asset, projectURL: fixture.package)
            release.open()
            await task.value
            state.expectUnchanged(asset, projectURL: fixture.package)
        }
    }

    @Test(arguments: [ClipType.image, .audio, .video])
    func unchangedSourceFinalizesRealMediaAndPersistsReadyState(type: ClipType) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let source: URL
            let filename: String
            switch type {
            case .image:
                source = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
                filename = "ready.png"
            case .audio:
                source = try await fixture.stage(Self.waveData())
                filename = "ready.wav"
            case .video:
                source = try await StoryboardTimingFixtures.video(in: fixture.root).url
                filename = "ready.mov"
            default:
                throw CocoaError(.fileReadUnknown)
            }
            var installed: MediaAsset?
            try await editor.projectPackageCoordinator.withMutation { lease in
                _ = try await editor.commitStagedProjectMedia(source, filename: filename, lease: lease) { url in
                    installed = makeAsset(url: url, type: type, editor: editor)
                }
            }
            let asset = try #require(installed)
            #expect(await editor.finalizeImportedAsset(asset))
            #expect(asset.generationStatus == .none)
            #expect(asset.inputIdentity?.isValid == true)
            #expect(asset.inputIdentityVerified)
            #expect(!editor.missingMediaRefs.contains(asset.id))
            #expect(!editor.unprocessableMediaRefs.contains(asset.id))
            switch type {
            case .image:
                #expect(asset.duration == Defaults.imageDurationSeconds)
                #expect(asset.sourceWidth == 2)
                #expect(asset.sourceHeight == 2)
                #expect(asset.thumbnail?.size == NSSize(width: 2, height: 2))
            case .audio:
                #expect(abs(asset.duration - 1) < 0.001)
                #expect(!asset.hasAudio)
            case .video:
                #expect(asset.duration == 5)
                #expect(asset.sourceWidth == 32)
                #expect(asset.sourceHeight == 32)
                #expect(asset.sourceFPS == 1)
                #expect(!asset.hasAudio)
                #expect(asset.thumbnail?.size == NSSize(width: 32, height: 32))
            default: break
            }
            try await savePackageTestDocument(document)
            let saved = try await fixture.readPackage()
            let entry = try #require(saved.manifest?.entries.first(where: { $0.id == asset.id }))
            #expect(entry == asset.toManifestEntry(projectURL: fixture.package))
            #expect(entry.generationStatus == nil)
            #expect(entry.generationInput?.backendJobId == "original-job")
            #expect(entry.generationInput?.outputIndex == 0)
            #expect(try await fixture.exists(asset.url))
        }
    }

    @Test(arguments: ["missing", "unreadable", "identity"])
    func currentFailurePublishesActionableManifestState(failure: String) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let source: URL
            if failure == "missing" {
                source = fixture.root.appendingPathComponent("missing.png")
            } else {
                let bytes = failure == "identity" ? try await MediaInputIdentityFixtures.imageData() : Data("INVALID".utf8)
                source = try await fixture.stage(bytes)
            }
            let asset = makeAsset(url: source, editor: editor)
            #expect(await !editor.finalizeImportedAsset(asset, identify: { _ in throw CocoaError(.fileReadCorruptFile) }))
            let message = failure == "identity" ? "Could not identify media file." : "Could not read media file."
            #expect(asset.generationStatus == .failed(message))
            #expect(editor.missingMediaRefs.contains(asset.id) == (failure == "missing"))
            #expect(editor.unprocessableMediaRefs.contains(asset.id) == (failure == "unreadable"))
            #expect(editor.mediaManifest.entries.first == asset.toManifestEntry(projectURL: fixture.package))
            #expect(asset.generationInput?.backendJobId == "original-job")
            #expect(asset.generationInput?.outputIndex == 0)
        }
    }

    @Test func realImageThumbnailPathsPreserveNativePixelsAndLargerBudget() async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let source = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
            let asset = makeAsset(url: source, editor: editor)
            await asset.loadLibraryThumbnail()
            #expect(asset.duration == Defaults.imageDurationSeconds)
            #expect(asset.thumbnail?.size == NSSize(width: 2, height: 2))
            await asset.loadPreviewThumbnail()
            let preview = try #require(asset.thumbnail)
            await asset.loadLibraryThumbnail()
            #expect(asset.thumbnail === preview)
            #expect(asset.generationStatus == .downloading)
            #expect(asset.sourceWidth == 2)
            #expect(asset.sourceHeight == 2)
        }
    }

    @Test(arguments: ["metadata", "metadataFailure", "metadataError", "metadataCanceled", "identity", "identityFailure", "identityCanceled"].flatMap { boundary in
        ["job", "output", "status", "readFailure", "identityFailure", "import", "source", "sourceABA", "object"].map { (boundary, $0) }
    }, [false, true])
    func downloadFinalizationRefusesSupersededContext(scenario: (String, String), cancelTask: Bool) async throws {
        let (boundary, change) = scenario
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let asset = makeDownloadAsset(editor: editor)
            let bytes = try await MediaInputIdentityFixtures.imageData()
            let stage = try await fixture.stage(bytes)
            let entered = FinalizationGate()
            let release = FinalizationGate()
            let service = GenerationService(downloadMedia: { _ in .init(fileURL: stage, httpStatusCode: 200) })
            var completions = 0
            var checkpoints = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            let task = Task {
                await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor, loadMetadata: { request in
                    if boundary.hasPrefix("metadata") {
                        await entered.open()
                        await release.wait()
                        switch boundary {
                        case "metadataFailure": return .init(isReadable: false, duration: 5)
                        case "metadataError": throw CocoaError(.fileReadCorruptFile)
                        case "metadataCanceled": throw CancellationError()
                        default: break
                        }
                    }
                    return try await MediaAssetMetadata.load(request)
                }, identify: { url in
                    if boundary.hasPrefix("identity") {
                        await entered.open()
                        await release.wait()
                        if boundary == "identityFailure" { throw CocoaError(.fileReadCorruptFile) }
                        if boundary == "identityCanceled" { throw CancellationError() }
                    }
                    return try await MediaInputIdentityService().identify(url)
                }, onComplete: { _ in completions += 1 })
            }
            await entered.wait()
            let installedURL = asset.url
            let current = retarget(asset, change: change, editor: editor, root: fixture.root)
            current.pendingDownloadURL = URL(string: "https://example.invalid/newer.png")!
            let oldState = AssetState(asset, projectURL: fixture.package)
            let currentState = AssetState(current, projectURL: fixture.package)
            let manifest = editor.mediaManifest
            let missing = editor.missingMediaRefs
            let unprocessable = editor.unprocessableMediaRefs
            let offline = editor.offlineMediaRefs
            if cancelTask { task.cancel() }
            release.open()
            #expect(await !task.value)
            #expect(editor.mediaAssetsById[asset.id] === current)
            oldState.expectUnchanged(asset, projectURL: fixture.package)
            currentState.expectUnchanged(current, projectURL: fixture.package)
            #expect(editor.mediaManifest == manifest)
            #expect(editor.missingMediaRefs == missing)
            #expect(editor.unprocessableMediaRefs == unprocessable)
            #expect(editor.offlineMediaRefs == offline)
            #expect(completions == 0)
            #expect(checkpoints == 0)
            #expect(try await fixture.contents(of: installedURL) == bytes)
            #expect(try await !fixture.exists(stage))
            try await savePackageTestDocument(document)
            let saved = try await fixture.readPackage()
            #expect(saved.manifest == manifest)
            currentState.expectUnchanged(current, projectURL: fixture.package)
        }
    }

    @Test(arguments: ["metadata", "identity"], [false, true])
    func matchingFinalizationCancellationSettlesBeforeQueuedSave(boundary: String, cancelTask: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let asset = makeDownloadAsset(editor: editor)
            let bytes = try await MediaInputIdentityFixtures.imageData()
            let stage = try await fixture.stage(bytes)
            let entered = FinalizationGate()
            let release = FinalizationGate()
            let service = GenerationService(downloadMedia: { _ in .init(fileURL: stage, httpStatusCode: 200) })
            var completions = 0
            var checkpoints = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            let task = Task {
                await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor, loadMetadata: { request in
                    if boundary == "metadata" {
                        await entered.open()
                        await release.wait()
                        if !cancelTask { throw CancellationError() }
                    }
                    return try await MediaAssetMetadata.load(request)
                }, identify: { url in
                    await entered.open()
                    await release.wait()
                    if !cancelTask { throw CancellationError() }
                    return try await MediaInputIdentityService().identify(url)
                }, onComplete: { _ in completions += 1 })
            }
            await entered.wait()
            let installedURL = asset.url
            let saved = PackageTestSignal()
            var saveError: Error?
            document.save(to: fixture.package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                saveError = error
                saved.signal()
            }
            if cancelTask { task.cancel() }
            release.open()
            #expect(await !task.value)
            await saved.wait()
            #expect(saveError == nil)
            #expect(!Task.isCancelled)
            #expect(asset.generationStatus == .failed("Generation canceled."))
            #expect(asset.pendingDownloadURL == remoteURL)
            #expect(asset.url == installedURL)
            #expect(completions == 0)
            #expect(checkpoints == 1)
            #expect(try await fixture.contents(of: installedURL) == bytes)
            #expect(try await !fixture.exists(stage))
            let package = try await fixture.readPackage()
            #expect(package.manifest?.entries.first == asset.toManifestEntry(projectURL: fixture.package))
            #expect(package.manifest?.entries.first?.generationStatus == "failed: Generation canceled.")
            #expect(package.manifest?.entries.first?.generationInput?.resultURLs == [remoteURL.absoluteString])
        }
    }

    @Test(arguments: ["unreadable", "metadataError", "identity"])
    func ownedFinalizationFailureRetainsInstalledBytesAndRetryLink(failure: String) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let asset = makeDownloadAsset(editor: editor)
            let bytes = failure == "unreadable" ? Data("INVALID".utf8) : try await MediaInputIdentityFixtures.imageData()
            let stage = try await fixture.stage(bytes)
            let service = GenerationService(downloadMedia: { _ in .init(fileURL: stage, httpStatusCode: 200) })
            var checkpoints = 0
            var completions = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            #expect(await !service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor, loadMetadata: { request in
                if failure == "metadataError" { throw CocoaError(.fileReadCorruptFile) }
                return try await MediaAssetMetadata.load(request)
            }, identify: { url in
                if failure == "identity" { throw CocoaError(.fileReadCorruptFile) }
                return try await MediaInputIdentityService().identify(url)
            }, onComplete: { _ in completions += 1 }))
            let message = failure == "identity" ? "Could not identify media file." : "Could not read media file."
            #expect(asset.generationStatus == .failed(message))
            #expect(asset.pendingDownloadURL == remoteURL)
            #expect(editor.unprocessableMediaRefs.contains(asset.id) == (failure != "identity"))
            #expect(!editor.missingMediaRefs.contains(asset.id))
            #expect(checkpoints == 1)
            #expect(completions == 0)
            #expect(try await fixture.contents(of: asset.url) == bytes)
            #expect(try await !fixture.exists(stage))
            try await savePackageTestDocument(document)
            let saved = try await fixture.readPackage()
            #expect(saved.manifest?.entries.first == asset.toManifestEntry(projectURL: fixture.package))
            #expect(saved.manifest?.entries.first?.generationInput?.resultURLs == [remoteURL.absoluteString])
        }
    }

    @Test func serviceFinalizesRealImageWithOneCompletionAndCheckpoint() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let asset = makeDownloadAsset(editor: editor)
            let bytes = try await MediaInputIdentityFixtures.imageData()
            let stage = try await fixture.stage(bytes)
            let service = GenerationService(downloadMedia: { _ in .init(fileURL: stage, httpStatusCode: 200) })
            var checkpoints = 0
            var completions = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            #expect(await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor, onComplete: { _ in completions += 1 }))
            #expect(asset.generationStatus == .none)
            #expect(asset.pendingDownloadURL == nil)
            #expect(asset.inputIdentityVerified)
            #expect(asset.duration == Defaults.imageDurationSeconds)
            #expect(asset.sourceWidth == 2)
            #expect(asset.sourceHeight == 2)
            #expect(checkpoints == 1)
            #expect(completions == 1)
            #expect(try await fixture.contents(of: asset.url) == bytes)
            #expect(try await !fixture.exists(stage))
            try await savePackageTestDocument(document)
            let saved = try await fixture.readPackage()
            #expect(saved.manifest?.entries.first == asset.toManifestEntry(projectURL: fixture.package))
            #expect(saved.manifest?.entries.first?.generationStatus == nil)
        }
    }

    @Test(arguments: ["return", "error", "cancellation"].flatMap { outcome in
        ["status", "import", "sourceABA"].map { (outcome, $0) }
    }, [false, true])
    func admittedDownloadCatchCannotSettleSupersededContext(scenario: (String, String), cancelTask: Bool) async throws {
        let (outcome, change) = scenario
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let asset = makeDownloadAsset(editor: editor)
            let originalURL = asset.url
            let stage = try await fixture.stage(try await MediaInputIdentityFixtures.imageData())
            let entered = FinalizationGate()
            let release = FinalizationGate()
            let service = GenerationService(downloadMedia: { _ in
                await entered.open()
                await release.wait()
                if outcome == "error" { throw URLError(.networkConnectionLost) }
                if outcome == "cancellation" { throw CancellationError() }
                return .init(fileURL: stage, httpStatusCode: 200)
            })
            var checkpoints = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            let task = Task { await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor) }
            await entered.wait()
            _ = retarget(asset, change: change, editor: editor, root: fixture.root)
            asset.pendingDownloadURL = URL(string: "https://example.invalid/newer.png")!
            let state = AssetState(asset, projectURL: fixture.package)
            let manifest = editor.mediaManifest
            if cancelTask { task.cancel() }
            release.open()
            #expect(await !task.value)
            state.expectUnchanged(asset, projectURL: fixture.package)
            #expect(editor.mediaManifest == manifest)
            #expect(checkpoints == 0)
            #expect(try await !fixture.exists(originalURL))
            #expect(try await fixture.exists(stage) == (outcome != "return"))
        }
    }

    @Test(arguments: ["admission", "retryStart"], ["status", "import"])
    func preAdmissionCancellationCannotSettleNewerParentContext(boundary: String, change: String) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let asset = makeDownloadAsset(editor: editor)
            asset.generationStatus = .failed("Download interrupted")
            asset.pendingDownloadURL = remoteURL
            let entered = FinalizationGate()
            let canceled = FinalizationGate()
            let release = FinalizationGate()
            let service = GenerationService(beforeTaskStart: {
                await withTaskCancellationHandler {
                    entered.open()
                    await release.wait()
                } onCancel: {
                    Task { @MainActor in canceled.open() }
                }
            }, downloadMedia: { _ in
                Issue.record("Superseded canceled attempt must not download")
                throw URLError(.unknown)
            })
            var checkpoints = 0
            editor.onProjectCheckpointRequired = { checkpoints += 1 }
            var fence: ProjectPackageCoordinator.SaveLease?
            var task: Task<Bool, Never>?
            if boundary == "admission" {
                editor.projectPackageCoordinator.enqueueSave { fence = $0 }
                task = Task {
                    entered.open()
                    return await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
                }
            } else {
                try service.retryDownload(asset: asset, editor: editor)
            }
            await entered.wait()
            _ = retarget(asset, change: change, editor: editor, root: fixture.root)
            let state = AssetState(asset, projectURL: fixture.package)
            let manifest = editor.mediaManifest
            if let task {
                task.cancel()
                #expect(await !task.value)
                editor.projectPackageCoordinator.finishSave(try #require(fence)) {}
            } else {
                let suspension = Task { await service.suspendAndWait() }
                await canceled.wait()
                release.open()
                await suspension.value
            }
            state.expectUnchanged(asset, projectURL: fixture.package)
            #expect(editor.mediaManifest == manifest)
            #expect(checkpoints == 0)
        }
    }

    @Test(arguments: ["status", "import"])
    func queuedAdmissionRefusesSupersededParentWithoutCancellation(change: String) async throws {
        try await withPackageTestFixture { fixture in
            let editor = fixture.document().editorViewModel
            let asset = makeDownloadAsset(editor: editor)
            let entered = FinalizationGate()
            let service = GenerationService(downloadMedia: { _ in
                Issue.record("Superseded queued attempt must not download")
                throw URLError(.unknown)
            })
            var fence: ProjectPackageCoordinator.SaveLease?
            editor.projectPackageCoordinator.enqueueSave { fence = $0 }
            let task = Task {
                entered.open()
                return await service.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
            }
            await entered.wait()
            _ = retarget(asset, change: change, editor: editor, root: fixture.root)
            let state = AssetState(asset, projectURL: fixture.package)
            let manifest = editor.mediaManifest
            editor.projectPackageCoordinator.finishSave(try #require(fence)) {}
            #expect(await !task.value)
            state.expectUnchanged(asset, projectURL: fixture.package)
            #expect(editor.mediaManifest == manifest)
        }
    }

    private func makeDownloadAsset(editor: EditorViewModel) -> MediaAsset {
        let asset = makeAsset(url: editor.projectURL!.appendingPathComponent("media/pending.png"), editor: editor)
        asset.generationInput?.resultURLs = [remoteURL.absoluteString]
        editor.updateManifestMetadata(for: [asset])
        return asset
    }

    private func makeAsset(url: URL, type: ClipType = .image, editor: EditorViewModel) -> MediaAsset {
        var input = GenerationInput(prompt: "Fixture", model: "fixture", duration: 0, aspectRatio: "16:9")
        input.backendJobId = "original-job"
        input.outputIndex = 0
        let asset = MediaAsset(url: url, type: type, name: "Fixture", duration: 17, generationInput: input)
        asset.generationStatus = .downloading
        asset.sourceWidth = 11
        asset.sourceHeight = 13
        asset.sourceFPS = 24
        editor.importMediaAsset(asset)
        return asset
    }

    private func retarget(_ asset: MediaAsset, change: String, editor: EditorViewModel, root: URL) -> MediaAsset {
        var current = asset
        switch change {
        case "job": asset.generationInput?.backendJobId = "newer-job"
        case "output": asset.generationInput?.outputIndex = 1
        case "status": asset.generationStatus = .failed("Newer failure")
        case "readFailure": asset.generationStatus = .failed("Could not read media file.")
        case "identityFailure": asset.generationStatus = .failed("Could not identify media file.")
        case "import": asset.importInput = MediaImportInput(sourceURL: "https://example.invalid/newer.png")
        case "source": asset.url = root.appendingPathComponent("newer.png")
        case "sourceABA":
            let original = asset.url
            asset.url = root.appendingPathComponent("newer.png")
            asset.url = original
        case "object":
            current = MediaAsset(id: asset.id, url: asset.url, type: .image, name: "Newer", generationInput: asset.generationInput)
            current.generationStatus = .generating
            editor.mediaAssets = [current]
        case "cancel": break
        default: Issue.record("Unknown fixture change")
        }
        if change != "cancel" {
            current.duration = 101
            current.sourceWidth = 201
            current.sourceHeight = 301
            current.sourceFPS = 48
            current.inputIdentity = MediaInputIdentity(contentSHA256: String(repeating: "f", count: 64), byteCount: 9)
            editor.updateManifestMetadata(for: [current])
        }
        return current
    }

    @MainActor
    private struct AssetState {
        let entry: MediaManifestEntry
        let thumbnail: NSImage?
        let identityVerified: Bool
        let context: MediaAsset.PreparationContext
        let pendingDownloadURL: URL?

        init(_ asset: MediaAsset, projectURL: URL) {
            entry = asset.toManifestEntry(projectURL: projectURL)
            thumbnail = asset.thumbnail
            identityVerified = asset.inputIdentityVerified
            context = asset.preparationContext
            pendingDownloadURL = asset.pendingDownloadURL
        }

        func expectUnchanged(_ asset: MediaAsset, projectURL: URL) {
            #expect(asset.toManifestEntry(projectURL: projectURL) == entry)
            #expect(asset.thumbnail === thumbnail)
            #expect(asset.inputIdentityVerified == identityVerified)
            #expect(asset.preparationContext == context)
            #expect(asset.pendingDownloadURL == pendingDownloadURL)
        }
    }

    private static func waveData() -> Data {
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32, bytes: Int) {
            for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        append(16_036, bytes: 4)
        data.append(Data("WAVEfmt ".utf8))
        append(16, bytes: 4)
        append(1, bytes: 2)
        append(1, bytes: 2)
        append(8_000, bytes: 4)
        append(16_000, bytes: 4)
        append(2, bytes: 2)
        append(16, bytes: 2)
        data.append(Data("data".utf8))
        append(16_000, bytes: 4)
        data.append(Data(repeating: 0, count: 16_000))
        return data
    }
}
