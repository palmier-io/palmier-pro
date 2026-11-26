import Foundation
import Testing
@testable import CompositorPro

/// `Thread.isMainThread` is unavailable directly in async contexts.
private func currentThreadIsMain() -> Bool { Thread.isMainThread }

@Suite("Folder relink")
@MainActor
struct FolderRelinkTests {    private final class ThreadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var main = true
        func record(_ isMain: Bool) {
            lock.lock()
            main = isMain
            lock.unlock()
        }

        var wasMain: Bool {
            lock.lock()
            defer { lock.unlock() }
            return main
        }
    }

    private func makeEditor(_ fixture: PackageTestFixture) async throws -> EditorViewModel {
        let document = fixture.document()
        document.editorViewModel.timeline = Fixtures.timeline(
            tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "clip", start: 0, duration: 30)])]
        )
        try await savePackageTestDocument(document)
        return document.editorViewModel
    }

    @Test func relinkMatchesNestedSameNamedFilesOnAWorker() async throws {
        try await withPackageTestFixture { fixture in
            let editor = try await makeEditor(fixture)
            let folder = fixture.root.appendingPathComponent("Media", isDirectory: true)
            let nested = folder.appendingPathComponent("Season 1", isDirectory: true)
            let files = try await fixture.io.perform { () -> (still: URL, nested: URL) in
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                let still = folder.appendingPathComponent("Shot A.png")
                let deep = nested.appendingPathComponent("SHOT-B.PNG")
                try Data("a".utf8).write(to: still)
                try Data("b".utf8).write(to: deep)
                return (still, deep)
            }
            let missing = fixture.root.appendingPathComponent("Missing", isDirectory: true)
            editor.mediaAssets = [
                MediaAsset(id: "a", url: missing.appendingPathComponent("Shot A.png"), type: .image, name: "Shot A.png"),
                MediaAsset(id: "b", url: missing.appendingPathComponent("shot-b.png"), type: .image, name: "shot-b.png"),
                MediaAsset(id: "c", url: missing.appendingPathComponent("Missing.png"), type: .image, name: "Missing.png"),
            ]
            editor.mediaManifest.entries = editor.mediaAssets.map { $0.toManifestEntry(projectURL: nil) }
            editor.offlineMediaRefs = ["a", "b", "c"]

            let probe = ThreadProbe()
            let result = await editor.relinkOfflineAssets(fromFolder: folder, scan: { folder, names in
                probe.record(currentThreadIsMain())
                return try EditorViewModel.indexFiles(in: folder, matching: names)
            })
            await editor.projectPackageCoordinator.waitUntilIdle()

            #expect(result == EditorViewModel.RelinkResult(relinked: 2, total: 3))
            #expect(!probe.wasMain)
            #expect(editor.mediaAssets.first { $0.id == "a" }?.url.resolvingSymlinksInPath()
                == files.still.resolvingSymlinksInPath())
            #expect(editor.mediaAssets.first { $0.id == "b" }?.url.resolvingSymlinksInPath()
                == files.nested.resolvingSymlinksInPath())
            #expect(editor.mediaAssets.first { $0.id == "c" }?.url.lastPathComponent == "Missing.png")
            #expect(editor.mediaManifest.entries.first { $0.id == "a" }?.source
                == editor.mediaAssets.first { $0.id == "a" }?.toManifestEntry(projectURL: editor.projectURL).source)
        }
    }

    @Test func cancelledRelinkPublishesNothing() async throws {
        try await withPackageTestFixture { fixture in
            let editor = try await makeEditor(fixture)
            let folder = fixture.root.appendingPathComponent("Cancel", isDirectory: true)
            let oldURL = fixture.root.appendingPathComponent("old/Shot.png")
            editor.mediaAssets = [MediaAsset(id: "a", url: oldURL, type: .image, name: "Shot.png")]
            editor.mediaManifest.entries = editor.mediaAssets.map { $0.toManifestEntry(projectURL: nil) }
            editor.offlineMediaRefs = ["a"]
            let manifestBefore = editor.mediaManifest.entries

            let entered = PackageTestSignal()
            let release = PackageTestSignal()
            let request = Task {
                await editor.relinkOfflineAssets(fromFolder: folder, scan: { _, _ in
                    await entered.signal()
                    await release.wait()
                    try Task.checkCancellation()
                    return ["shot.png": folder.appendingPathComponent("Shot.png")]
                })
            }
            await entered.wait()
            editor.cancelRelinkScan()
            release.signal()

            #expect(await request.value == nil)
            #expect(editor.mediaAssets.first?.url == oldURL)
            #expect(editor.mediaManifest.entries == manifestBefore)
            await editor.projectPackageCoordinator.waitUntilIdle()
        }
    }

    @Test func relinkSkipsTargetsThatChangedDuringTheScan() async throws {
        try await withPackageTestFixture { fixture in
            let editor = try await makeEditor(fixture)
            let folder = fixture.root.appendingPathComponent("Stale", isDirectory: true)
            let oldURL = fixture.root.appendingPathComponent("old/Shot.png")
            editor.mediaAssets = [MediaAsset(id: "a", url: oldURL, type: .image, name: "Shot.png")]
            editor.offlineMediaRefs = ["a"]

            let entered = PackageTestSignal()
            let release = PackageTestSignal()
            let request = Task {
                await editor.relinkOfflineAssets(fromFolder: folder, scan: { _, _ in
                    await entered.signal()
                    await release.wait()
                    return ["shot.png": folder.appendingPathComponent("Shot.png")]
                })
            }
            await entered.wait()
            // The asset was relinked or rechecked while the scan was in flight.
            editor.offlineMediaRefs = []
            release.signal()

            #expect(await request.value == EditorViewModel.RelinkResult(relinked: 0, total: 1))
            #expect(editor.mediaAssets.first?.url == oldURL)
            await editor.projectPackageCoordinator.waitUntilIdle()
        }
    }
}
