import Foundation
import Testing
@testable import PalmierPro

@Suite("Palmier project export (collect media)")
struct PalmierProjectExportTests {

    private let fm = FileManager.default

    /// Builds a throwaway source bundle: one internal (project-relative) clip, one external
    /// clip that exists, one external clip whose file is gone. Returns (source, dest, externalURL).
    private func makeFixture() throws -> (root: URL, source: URL, dest: URL, externalContents: String) {
        let root = fm.temporaryDirectory.appendingPathComponent("pp-export-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source.palmier", isDirectory: true)
        let sourceMedia = source.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try fm.createDirectory(at: sourceMedia, withIntermediateDirectories: true)

        try Data("INTERNAL-BYTES".utf8).write(to: sourceMedia.appendingPathComponent("gen-abc123.mp4"))
        try Data("JPEG".utf8).write(to: source.appendingPathComponent(Project.thumbnailFilename))

        let externalContents = "EXTERNAL-BYTES"
        try Data(externalContents.utf8).write(to: root.appendingPathComponent("external-clip.mov"))

        return (root, source, root.appendingPathComponent("Packaged.palmier", isDirectory: true), externalContents)
    }

    private func manifest(externalPath: String) -> MediaManifest {
        var m = MediaManifest()
        m.entries = [
            MediaManifestEntry(id: "proj-1", name: "Internal", type: .video,
                               source: .project(relativePath: "media/gen-abc123.mp4"), duration: 1),
            MediaManifestEntry(id: "ext-1", name: "External", type: .video,
                               source: .external(absolutePath: externalPath), duration: 1),
            MediaManifestEntry(id: "miss-1", name: "Gone", type: .video,
                               source: .external(absolutePath: "/nonexistent/gone.mov"), duration: 1),
        ]
        return m
    }

    @Test func collectsExternalAndInternalRewritesSourcesReportsMissing() throws {
        let (root, source, dest, externalContents) = try makeFixture()
        defer { try? fm.removeItem(at: root) }

        let report = try PalmierProjectExporter.export(
            projectFile: ProjectFile(timelines: [Fixtures.timeline()], activeTimelineId: nil, openTimelineIds: nil),
            manifest: manifest(externalPath: root.appendingPathComponent("external-clip.mov").path),
            generationLog: GenerationLog(),
            sourceProjectURL: source,
            to: dest
        )

        #expect(report.collected == ["ext-1"])
        #expect(report.copiedInternal == 1)
        #expect(report.missing == [.init(id: "miss-1", name: "Gone")])
        #expect(report.totalBytes > 0)

        // Bundle structure written.
        for name in [Project.timelineFilename, Project.manifestFilename, Project.generationLogFilename, Project.thumbnailFilename] {
            #expect(fm.fileExists(atPath: dest.appendingPathComponent(name).path), "missing \(name)")
        }

        // Manifest sources rewritten: resolvable entries internalized, missing one untouched.
        let outManifest = try JSONDecoder().decode(
            MediaManifest.self, from: Data(contentsOf: dest.appendingPathComponent(Project.manifestFilename))
        )
        let byId = Dictionary(uniqueKeysWithValues: outManifest.entries.map { ($0.id, $0.source) })
        if case .project = byId["proj-1"] {} else { Issue.record("proj-1 should stay project") }
        if case .project = byId["ext-1"] {} else { Issue.record("ext-1 should become project") }
        if case .external = byId["miss-1"] {} else { Issue.record("miss-1 should stay external") }

        // The collected external file was copied with its bytes intact.
        if case .project(let rel) = byId["ext-1"] {
            let copied = try String(contentsOf: dest.appendingPathComponent(rel), encoding: .utf8)
            #expect(copied == externalContents)
        }
    }

    /// The whole point: the exported bundle resolves every non-missing entry against itself.
    @Test func exportedBundleRoundTripsWithZeroUnresolvedMedia() throws {
        let (root, source, dest, _) = try makeFixture()
        defer { try? fm.removeItem(at: root) }

        try PalmierProjectExporter.export(
            projectFile: ProjectFile(timelines: [Fixtures.timeline()], activeTimelineId: nil, openTimelineIds: nil),
            manifest: manifest(externalPath: root.appendingPathComponent("external-clip.mov").path),
            generationLog: GenerationLog(),
            sourceProjectURL: source,
            to: dest
        )

        let outManifest = try JSONDecoder().decode(
            MediaManifest.self, from: Data(contentsOf: dest.appendingPathComponent(Project.manifestFilename))
        )
        let resolver = MediaResolver(manifest: { outManifest }, projectURL: { dest })
        #expect(resolver.resolveURL(for: "proj-1") != nil)
        #expect(resolver.resolveURL(for: "ext-1") != nil)
        #expect(resolver.resolveURL(for: "miss-1") == nil)   // genuinely gone — stays unresolved
    }

    @Test func deduplicatesTwoEntriesPointingAtTheSameExternalFile() throws {
        let (root, source, dest, _) = try makeFixture()
        defer { try? fm.removeItem(at: root) }

        let externalPath = root.appendingPathComponent("external-clip.mov").path
        var m = MediaManifest()
        m.entries = [
            MediaManifestEntry(id: "a", name: "A", type: .video, source: .external(absolutePath: externalPath), duration: 1),
            MediaManifestEntry(id: "b", name: "B", type: .video, source: .external(absolutePath: externalPath), duration: 1),
        ]

        let report = try PalmierProjectExporter.export(
            projectFile: ProjectFile(timelines: [Fixtures.timeline()], activeTimelineId: nil, openTimelineIds: nil), manifest: m, generationLog: GenerationLog(),
            sourceProjectURL: source, to: dest
        )

        #expect(report.collected.sorted() == ["a", "b"])
        // Only one physical file copied into media/.
        let mediaFiles = try fm.contentsOfDirectory(atPath: dest.appendingPathComponent(Project.mediaDirectoryName).path)
        #expect(mediaFiles.count == 1)
    }
}
