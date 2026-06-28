import Foundation
import Testing
@testable import PalmierPro

@Suite("Project document IO")
@MainActor
struct ProjectDocumentIOTests {
    private let fm = FileManager.default

    @Test func directWritePreservesExistingPackageMediaAndThumbnail() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("pp-doc-io-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Project.palmier", isDirectory: true)
        try makePackage(at: package)
        defer { try? fm.removeItem(at: root) }

        let doc = configuredDocument(fileURL: package)
        try doc.write(to: package, ofType: VideoProject.typeIdentifier)

        #expect(try String(contentsOf: package.appendingPathComponent("media/clip.mp4"), encoding: .utf8) == "MEDIA")
        #expect(try String(contentsOf: package.appendingPathComponent(Project.thumbnailFilename), encoding: .utf8) == "THUMB")
        #expect(fm.fileExists(atPath: package.appendingPathComponent(ChatSessionStore.dirName).path))
    }

    @Test func directWriteCopiesPackageMediaAndThumbnailToNewDestination() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("pp-doc-io-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source.palmier", isDirectory: true)
        let destination = root.appendingPathComponent("Destination.palmier", isDirectory: true)
        try makePackage(at: source)
        defer { try? fm.removeItem(at: root) }

        let doc = configuredDocument(fileURL: source)
        try doc.write(to: destination, ofType: VideoProject.typeIdentifier)

        #expect(try String(contentsOf: destination.appendingPathComponent("media/clip.mp4"), encoding: .utf8) == "MEDIA")
        #expect(try String(contentsOf: destination.appendingPathComponent(Project.thumbnailFilename), encoding: .utf8) == "THUMB")
        #expect(fm.fileExists(atPath: destination.appendingPathComponent(Project.timelineFilename).path))
        #expect(fm.fileExists(atPath: destination.appendingPathComponent(Project.manifestFilename).path))
    }

    @Test func editorMarkerAndBlendModePersistIntoProjectPackage() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("pp-doc-io-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Project.palmier", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let clipId = "logo-clip"
        let doc = VideoProject()
        doc.fileURL = package
        doc.fileType = VideoProject.typeIdentifier
        doc.editorViewModel.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: clipId, mediaType: .image, start: 0, duration: 60)
            ])
        ])
        doc.editorViewModel.onDocumentEdited = { [weak doc] in
            doc?.updateChangeCount(.changeDone)
        }

        let marker = doc.editorViewModel.addTimelineMarker(
            frame: 24,
            label: "Logo beat",
            color: "#F29933"
        )
        doc.editorViewModel.commitClipProperty(clipId: clipId) {
            $0.blendMode = .difference
        }

        #expect(doc.isDocumentEdited)

        try doc.write(to: package, ofType: VideoProject.typeIdentifier)
        let data = try Data(contentsOf: package.appendingPathComponent(Project.timelineFilename))
        let saved = try JSONDecoder().decode(Timeline.self, from: data)
        let savedClip = try #require(saved.tracks.first?.clips.first)

        #expect(saved.markers == [marker])
        #expect(savedClip.id == clipId)
        #expect(savedClip.blendMode == .difference)
    }

    private func makePackage(at url: URL) throws {
        let media = url.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("MEDIA".utf8).write(to: media.appendingPathComponent("clip.mp4"))
        try Data("THUMB".utf8).write(to: url.appendingPathComponent(Project.thumbnailFilename))
    }

    private func configuredDocument(fileURL: URL) -> VideoProject {
        let doc = VideoProject()
        doc.fileURL = fileURL
        doc.fileType = VideoProject.typeIdentifier
        doc.editorViewModel.timeline = Fixtures.timeline()
        var manifest = MediaManifest()
        manifest.entries = [
            MediaManifestEntry(
                id: "clip",
                name: "Clip",
                type: .video,
                source: .project(relativePath: "media/clip.mp4"),
                duration: 1
            )
        ]
        doc.editorViewModel.mediaManifest = manifest
        return doc
    }
}
