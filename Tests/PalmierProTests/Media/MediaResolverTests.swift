import Foundation
import Testing
@testable import PalmierPro

@Suite("MediaResolver")
struct MediaResolverTests {

    private func entry(
        id: String,
        name: String = "X",
        source: MediaSource
    ) -> MediaManifestEntry {
        MediaManifestEntry(id: id, name: name, type: .video, source: source, duration: 1)
    }

    /// Writes an empty file to a temp dir and returns its URL.
    private func makeTempFile(name: String = "f-\(UUID().uuidString).mp4") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    // MARK: - entry(for:)

    @Test func entryReturnsMatchingEntry() {
        let e = entry(id: "a", source: .external(absolutePath: "/tmp/a"))
        var manifest = MediaManifest()
        manifest.entries = [e]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        #expect(resolver.entry(for: "a")?.id == "a")
    }

    @Test func entryReturnsNilWhenMissing() {
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { nil })
        #expect(resolver.entry(for: "ghost") == nil)
    }

    // MARK: - displayName

    @Test func displayNameReturnsEntryName() {
        let e = entry(id: "a", name: "Hello", source: .external(absolutePath: "/tmp/a"))
        var manifest = MediaManifest()
        manifest.entries = [e]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        #expect(resolver.displayName(for: "a") == "Hello")
    }

    @Test func displayNameFallsBackToOfflineWhenMissing() {
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { nil })
        #expect(resolver.displayName(for: "ghost") == "Offline")
    }

    // MARK: - resolveURL: external source

    @Test func resolveExternalReturnsURLWhenFileExists() throws {
        let file = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let e = entry(id: "a", source: .external(absolutePath: file.path))
        var manifest = MediaManifest()
        manifest.entries = [e]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        #expect(resolver.resolveURL(for: "a")?.path == file.path)
    }

    @Test func resolveExternalReturnsNilWhenFileMissing() {
        let e = entry(id: "a", source: .external(absolutePath: "/tmp/does-not-exist-\(UUID().uuidString)"))
        var manifest = MediaManifest()
        manifest.entries = [e]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        #expect(resolver.resolveURL(for: "a") == nil)
    }

    // MARK: - resolveURL: project-relative source

    @Test func resolveProjectAppendsRelativePathToProjectURL() throws {
        // Build a project dir with a file inside it.
        let projectDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let inner = projectDir.appendingPathComponent("media/asset.mp4")
        try FileManager.default.createDirectory(at: inner.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inner.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let e = entry(id: "a", source: .project(relativePath: "media/asset.mp4"))
        var manifest = MediaManifest()
        manifest.entries = [e]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { projectDir })

        #expect(resolver.resolveURL(for: "a")?.path == inner.path)
    }

    @Test func resolveProjectReturnsNilWhenProjectURLIsNil() {
        let e = entry(id: "a", source: .project(relativePath: "media/asset.mp4"))
        var manifest = MediaManifest()
        manifest.entries = [e]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        #expect(resolver.resolveURL(for: "a") == nil)
    }

    // MARK: - Cache behavior

    @Test func entryCacheRebuildsWhenEntryCountChanges() {
        var entries = [entry(id: "a", source: .external(absolutePath: "/tmp/a"))]
        var manifest = MediaManifest()
        manifest.entries = entries
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        _ = resolver.entry(for: "a") // warm the cache

        // Add a new entry — count changes, cache rebuilds.
        entries.append(entry(id: "b", source: .external(absolutePath: "/tmp/b")))
        manifest.entries = entries
        #expect(resolver.entry(for: "b")?.id == "b")
    }
}

// MARK: - Live-manifest reads

/// Pins the contract that the resolver always reflects the *current* manifest state.
/// A previous version cached by entry-array count and went stale on same-count mutations
/// (rename, replace, reorder) — these tests guard against that regression.
@Suite("MediaResolver — live reads")
struct MediaResolverLiveReadTests {

    private func entry(id: String, name: String = "X") -> MediaManifestEntry {
        MediaManifestEntry(id: id, name: name, type: .video, source: .external(absolutePath: "/tmp/\(id)"), duration: 1)
    }

    @Test func reflectsReplacedEntryAtSameCount() {
        var manifest = MediaManifest()
        manifest.entries = [entry(id: "a"), entry(id: "b")]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        _ = resolver.entry(for: "a") // would warm any cache

        // Replace "b" with "c" — same count, different identity.
        manifest.entries = [entry(id: "a"), entry(id: "c")]
        #expect(resolver.entry(for: "c")?.id == "c")
        #expect(resolver.entry(for: "b") == nil)
    }

    @Test func reflectsRenamedEntryAtSameCount() {
        var manifest = MediaManifest()
        manifest.entries = [entry(id: "a", name: "First")]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })

        _ = resolver.entry(for: "a")
        manifest.entries = [entry(id: "a", name: "Renamed")]
        #expect(resolver.entry(for: "a")?.name == "Renamed")
    }
}
