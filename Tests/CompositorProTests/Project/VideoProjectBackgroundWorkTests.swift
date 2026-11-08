import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class DocumentThumbnailProbe {
    let started = PackageTestSignal()
    let release: PackageTestSignal?
    private(set) var calls = 0

    init(paused: Bool = false) { release = paused ? PackageTestSignal() : nil }

    func render(_ request: VideoProject.ThumbnailRequest) async -> Data? {
        calls += 1
        let call = calls
        started.signal()
        if let release { await release.wait() }
        return Data("thumbnail-\(call)".utf8)
    }
}

@MainActor
@Suite("VideoProject owned background work")
struct VideoProjectBackgroundWorkTests {
    enum ThumbnailChange: CaseIterable, Sendable {
        case timeline, trim, fps, source, assetURL, assetReplacement, generation
    }

    enum RestoreChange: CaseIterable, Sendable {
        case removal, manifest, source, assetURL, assetReplacement, generation, project
    }

    private func entry(_ id: String, url: URL, type: ClipType = .image) -> MediaManifestEntry {
        MediaManifestEntry(id: id, name: id, type: type, source: .external(absolutePath: url.path), duration: 1)
    }

    private func configureThumbnail(_ document: VideoProject, url: URL) {
        let item = entry("thumbnail", url: url)
        document.editorViewModel.mediaManifest.entries = [item]
        document.editorViewModel.mediaAssets = [MediaAsset(entry: item, resolvedURL: url)]
        document.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: item.id, mediaType: .image, start: 0, duration: 30)
        ])])
    }

    @Test(arguments: ThumbnailChange.allCases)
    func thumbnailCacheInvalidatesCurrentCandidateAndConfiguration(_ change: ThumbnailChange) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = try await fixture.stage()
            configureThumbnail(document, url: source)
            let probe = DocumentThumbnailProbe()
            document.thumbnailRenderer = { await probe.render($0) }
            let coordinator = document.editorViewModel.projectPackageCoordinator
            #expect(document.captureThumbnail() == nil)
            await coordinator.waitUntilIdle()
            #expect(document.captureThumbnail() == Data("thumbnail-1".utf8))
            await coordinator.waitUntilIdle()
            let editor = document.editorViewModel
            let asset = try #require(editor.mediaAssets.first)
            switch change {
            case .timeline: editor.timeline.id = "another-timeline"
            case .trim: editor.timeline.tracks[0].clips[0].trimStartFrame = 15
            case .fps: editor.timeline.fps = 60
            case .source:
                let changed = source.appendingPathExtension("changed")
                editor.mediaManifest.entries[0].source = .external(absolutePath: changed.path)
                asset.url = changed
            case .assetURL: asset.url = source.appendingPathExtension("changed")
            case .assetReplacement: editor.mediaAssets = [MediaAsset(entry: editor.mediaManifest.entries[0], resolvedURL: source)]
            case .generation: asset.generationStatus = .rendering
            }
            #expect(document.captureThumbnail() == nil)
            await coordinator.waitUntilIdle()
            #expect(document.captureThumbnail() == (change == .assetURL ? nil : Data("thumbnail-2".utf8)))
            await coordinator.waitUntilIdle()
            #expect(probe.calls == (change == .assetURL ? 1 : 2))
        }
    }

    @Test func thumbnailRevalidatesExternalFileWithoutRepeatedDecoding() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = try await fixture.stage()
            configureThumbnail(document, url: source)
            let probe = DocumentThumbnailProbe()
            document.thumbnailRenderer = { await probe.render($0) }
            let coordinator = document.editorViewModel.projectPackageCoordinator
            var checkpoints = 0
            document.editorViewModel.onProjectCheckpointRequired = { checkpoints += 1 }
            _ = document.captureThumbnail()
            await coordinator.waitUntilIdle()
            _ = document.captureThumbnail()
            await coordinator.waitUntilIdle()
            #expect(probe.calls == 1)
            try await fixture.io.perform { try Data("CHANGED-CONTENT".utf8).write(to: source, options: .atomic) }
            _ = document.captureThumbnail()
            await coordinator.waitUntilIdle()
            #expect(document.captureThumbnail() == Data("thumbnail-2".utf8))
            await coordinator.waitUntilIdle()
            #expect(probe.calls == 2)
            #expect(checkpoints == 2)
        }
    }

    @Test func thumbnailRejectsFileChangedDuringRendering() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = try await fixture.stage()
            configureThumbnail(document, url: source)
            let probe = DocumentThumbnailProbe(paused: true)
            document.thumbnailRenderer = { await probe.render($0) }
            var checkpoints = 0
            document.editorViewModel.onProjectCheckpointRequired = { checkpoints += 1 }
            _ = document.captureThumbnail()
            await probe.started.wait()
            try await fixture.io.perform { try Data("CHANGED-CONTENT".utf8).write(to: source, options: .atomic) }
            probe.release?.signal()
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(checkpoints == 0)
            #expect(document.captureThumbnail() == nil)
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(document.captureThumbnail() == Data("thumbnail-2".utf8))
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
        }
    }

    @Test(arguments: [false, true])
    func thumbnailCloseCancellationDrainsWithoutLateCheckpoint(withRetry: Bool) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            configureThumbnail(document, url: try await fixture.stage())
            let probe = DocumentThumbnailProbe(paused: true)
            document.thumbnailRenderer = { await probe.render($0) }
            var checkpoints = 0
            document.editorViewModel.onProjectCheckpointRequired = { checkpoints += 1 }
            let coordinator = document.editorViewModel.projectPackageCoordinator
            _ = document.captureThumbnail()
            await probe.started.wait()
            if withRetry {
                document.editorViewModel.timeline.tracks[0].clips[0].trimStartFrame = 10
                #expect(document.captureThumbnail() == nil)
            }
            let close = try #require(coordinator.beginClosing())
            document.cancelDocumentBackgroundWork()
            #expect(!coordinator.canFinishClosing)
            probe.release?.signal()
            await coordinator.waitUntilIdle()
            #expect(coordinator.canFinishClosing)
            try coordinator.finishClosing(close)
            #expect(document.captureThumbnail() == nil)
            #expect(checkpoints == 0)
            #expect(probe.calls == 1)
        }
    }

    @Test func thumbnailRetriesCurrentRequestAfterStaleCompletion() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            configureThumbnail(document, url: try await fixture.stage())
            let probe = DocumentThumbnailProbe(paused: true)
            document.thumbnailRenderer = { await probe.render($0) }
            var checkpoints = 0
            document.editorViewModel.onProjectCheckpointRequired = { checkpoints += 1 }
            _ = document.captureThumbnail()
            await probe.started.wait()
            document.editorViewModel.timeline.tracks[0].clips[0].trimStartFrame = 10
            #expect(document.captureThumbnail() == nil)
            document.editorViewModel.timeline.tracks[0].clips[0].trimStartFrame = 20
            #expect(document.captureThumbnail() == nil)
            probe.release?.signal()
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(document.captureThumbnail() == Data("thumbnail-2".utf8))
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(checkpoints == 1)
            #expect(probe.calls == 2)
        }
    }

    @Test(arguments: RestoreChange.allCases)
    func restoreScanRejectsChangedSourceAndGenerationState(_ change: RestoreChange) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = fixture.root.appendingPathComponent("missing-video.mp4")
            var item = entry("restore", url: source, type: .video)
            item.importInput = MediaImportInput(sourcePath: source.path)
            item.generationStatus = "downloading"
            document.editorViewModel.mediaManifest.entries = [item]
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            document.mediaRestoreScanner = { _ in
                await started.signal()
                await release.wait()
                return []
            }
            document.restoreAssetsFromManifest()
            await started.wait()
            let editor = document.editorViewModel
            let original = try #require(editor.mediaAssets.first)
            editor.missingMediaRefs = ["concurrent-missing"]
            switch change {
            case .removal:
                editor.mediaAssets = []
                editor.mediaManifest.entries = []
            case .manifest: editor.mediaManifest.entries[0].name = "New name"
            case .source: editor.mediaManifest.entries[0].source = .external(absolutePath: source.path + "-new")
            case .assetURL: original.url = source.appendingPathExtension("new")
            case .assetReplacement: editor.mediaAssets = [MediaAsset(entry: item, resolvedURL: source)]
            case .generation: original.generationStatus = .rendering
            case .project: editor.projectURL = fixture.root.appendingPathComponent("New.palmier")
            }
            release.signal()
            await editor.projectPackageCoordinator.waitUntilIdle()
            #expect(editor.missingMediaRefs == ["concurrent-missing"])
            #expect(original.generationStatus == (change == .generation ? .rendering : .downloading))
            if change == .removal {
                #expect(editor.mediaAssets.isEmpty)
                #expect(editor.mediaManifest.entries.isEmpty)
            }
            if change == .assetReplacement {
                #expect(editor.mediaAssets.first !== original)
                #expect(editor.mediaAssets.first?.generationStatus == .downloading)
            }
        }
    }

    @Test func restorePreservesConcurrentMissingRefsAndAvoidsDuplicateAssets() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let item = entry("restore", url: fixture.root.appendingPathComponent("missing.png"))
            document.editorViewModel.mediaManifest.entries = [item, item]
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            document.mediaRestoreScanner = { _ in
                await started.signal()
                await release.wait()
                return []
            }
            document.restoreAssetsFromManifest()
            await started.wait()
            document.editorViewModel.missingMediaRefs = ["concurrent-missing"]
            release.signal()
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            document.restoreAssetsFromManifest()
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(document.editorViewModel.mediaAssets.count == 1)
            #expect(document.editorViewModel.missingMediaRefs == ["restore", "concurrent-missing"])
        }
    }

    @Test func restoreHydratesSequentiallyAndKeepsUnusedMediaLazy() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = try await fixture.stage()
            document.editorViewModel.mediaManifest.entries = ["first", "second", "unused"].map {
                entry($0, url: source, type: .lottie)
            }
            document.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "first", mediaType: .lottie, start: 0, duration: 30),
                Fixtures.clip(mediaRef: "second", mediaType: .lottie, start: 30, duration: 30)
            ])])
            document.mediaRestoreScanner = { Set($0) }
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            var loaded: [String] = []
            var active = 0
            var maximumActive = 0
            document.restoredMetadataLoader = { asset in
                active += 1
                maximumActive = max(maximumActive, active)
                loaded.append(asset.id)
                if asset.id == "first" {
                    started.signal()
                    await release.wait()
                }
                asset.sourceWidth = 640
                asset.sourceHeight = 360
                active -= 1
                return true
            }
            document.restoreAssetsFromManifest()
            await started.wait()
            #expect(loaded == ["first"])
            #expect(document.editorViewModel.mediaAssetsById["first"]?.sourceWidth == nil)
            release.signal()
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(loaded == ["first", "second"])
            #expect(maximumActive == 1)
            #expect(document.editorViewModel.mediaAssetsById["first"]?.sourceWidth == 640)
            #expect(document.editorViewModel.mediaAssetsById["second"]?.sourceWidth == 640)
            #expect(document.editorViewModel.mediaAssetsById["unused"]?.sourceWidth == nil)
            #expect(document.editorViewModel.mediaManifest.entries.first { $0.id == "first" }?.sourceWidth == 640)
        }
    }

    @Test(arguments: RestoreChange.allCases)
    func restoreHydrationRejectsLateResults(_ change: RestoreChange) async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = try await fixture.stage()
            document.editorViewModel.mediaManifest.entries = [entry("restore", url: source, type: .lottie)]
            document.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "restore", mediaType: .lottie, start: 0, duration: 30)
            ])])
            document.mediaRestoreScanner = { Set($0) }
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            document.restoredMetadataLoader = { asset in
                started.signal()
                await release.wait()
                asset.sourceWidth = 640
                return true
            }
            document.restoreAssetsFromManifest()
            await started.wait()
            let editor = document.editorViewModel
            let original = try #require(editor.mediaAssets.first)
            switch change {
            case .removal:
                editor.mediaAssets = []
                editor.mediaManifest.entries = []
            case .manifest: editor.mediaManifest.entries[0].sourceWidth = 999
            case .source: editor.mediaManifest.entries[0].source = .external(absolutePath: source.path + "-new")
            case .assetURL: original.url = source.appendingPathExtension("new")
            case .assetReplacement: editor.mediaAssets = [MediaAsset(entry: editor.mediaManifest.entries[0], resolvedURL: source)]
            case .generation: original.generationStatus = .rendering
            case .project: editor.projectURL = fixture.root.appendingPathComponent("New.palmier")
            }
            release.signal()
            await editor.projectPackageCoordinator.waitUntilIdle()
            #expect(original.sourceWidth == nil)
            #expect(editor.mediaAssets.first?.sourceWidth == nil)
            if change == .manifest { #expect(editor.mediaManifest.entries.first?.sourceWidth == 999) }
            if change == .removal { #expect(editor.mediaManifest.entries.isEmpty) }
        }
    }

    @Test func restoreCloseCancellationDrainsWithoutMetadataCommit() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = try await fixture.stage()
            document.editorViewModel.mediaManifest.entries = [entry("restore", url: source, type: .lottie)]
            document.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "restore", mediaType: .lottie, start: 0, duration: 30)
            ])])
            document.mediaRestoreScanner = { Set($0) }
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            document.restoredMetadataLoader = { asset in
                started.signal()
                await release.wait()
                asset.sourceWidth = 640
                return true
            }
            document.restoreAssetsFromManifest()
            await started.wait()
            let coordinator = document.editorViewModel.projectPackageCoordinator
            coordinator.beginClosing()
            document.cancelDocumentBackgroundWork()
            #expect(!coordinator.canFinishClosing)
            release.signal()
            await coordinator.waitUntilIdle()
            #expect(coordinator.canFinishClosing)
            #expect(document.editorViewModel.mediaAssets.first?.sourceWidth == nil)
            #expect(document.editorViewModel.mediaManifest.entries.first?.sourceWidth == nil)
        }
    }

    @Test func supersededRestoreWaitsForPriorScanAndPreservesRecoveryEligibility() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = fixture.root.appendingPathComponent("missing.mp4")
            var item = entry("restore", url: source, type: .video)
            item.importInput = MediaImportInput(sourcePath: source.path)
            item.generationStatus = "downloading"
            document.editorViewModel.mediaManifest.entries = [item]
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            let scanCount = DocumentScanProbe(started: started, release: release)
            document.mediaRestoreScanner = { await scanCount.scan($0) }
            document.restoreAssetsFromManifest()
            await started.wait()
            document.restoreAssetsFromManifest()
            release.signal()
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(scanCount.calls == 2)
            #expect(scanCount.maximumActive == 1)
            #expect(document.editorViewModel.mediaAssets.count == 1)
            #expect(document.editorViewModel.mediaAssets.first?.generationStatus == .failed("Import interrupted"))
        }
    }

    @Test func sourceChangedWhileEarlierAssetHydratesDoesNotStartObsoleteHydration() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let source = try await fixture.stage()
            document.editorViewModel.mediaManifest.entries = ["first", "second"].map { entry($0, url: source, type: .lottie) }
            document.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "first", mediaType: .lottie, start: 0, duration: 30),
                Fixtures.clip(mediaRef: "second", mediaType: .lottie, start: 30, duration: 30)
            ])])
            document.mediaRestoreScanner = { Set($0) }
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            var loaded: [String] = []
            document.restoredMetadataLoader = { asset in
                loaded.append(asset.id)
                started.signal()
                await release.wait()
                asset.sourceWidth = 640
                return true
            }
            document.restoreAssetsFromManifest()
            await started.wait()
            document.editorViewModel.mediaAssetsById["second"]?.url = source.appendingPathExtension("changed")
            release.signal()
            await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
            #expect(loaded == ["first"])
            #expect(document.editorViewModel.mediaAssetsById["first"]?.sourceWidth == 640)
            #expect(document.editorViewModel.mediaAssetsById["second"]?.sourceWidth == nil)
        }
    }
}

@MainActor
private final class DocumentScanProbe {
    let started: PackageTestSignal
    let release: PackageTestSignal
    private(set) var calls = 0
    private var active = 0
    private(set) var maximumActive = 0

    init(started: PackageTestSignal, release: PackageTestSignal) {
        self.started = started
        self.release = release
    }

    func scan(_ urls: [URL]) async -> Set<URL> {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        started.signal()
        await release.wait()
        active -= 1
        return []
    }
}
