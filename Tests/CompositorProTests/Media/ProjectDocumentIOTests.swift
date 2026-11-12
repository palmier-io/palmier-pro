import Foundation
import Testing
@testable import CompositorPro

@Suite("Project document IO", .serialized)
@MainActor
struct ProjectDocumentIOTests {
    @Test func nativeSavePreservesExistingPackageMediaAndThumbnail() async throws {
        try await withPackageTestFixture { fixture in
            try await makePackage(at: fixture.package, io: fixture.io)
            let document = configuredDocument(fixture)
            try await savePackageTestDocument(document)
            #expect(try await fixture.contents(of: fixture.package.appendingPathComponent("media/clip.mp4")) == Data("MEDIA".utf8))
            #expect(try await fixture.contents(of: fixture.package.appendingPathComponent(Project.thumbnailFilename)) == Data("THUMB".utf8))
            #expect(try await fixture.exists(fixture.package.appendingPathComponent(ChatSessionStore.dirName)))
        }
    }

    @Test func nativeSaveCopyIncludesMediaAndThumbnailAtNewDestination() async throws {
        try await withPackageTestFixture { fixture in
            try await makePackage(at: fixture.package, io: fixture.io)
            let destination = fixture.root.appendingPathComponent("Copy.compositorpro", isDirectory: true)
            let document = configuredDocument(fixture)
            try await savePackageTestDocument(document, to: destination, operation: .saveToOperation)
            #expect(document.fileURL == fixture.package)
            #expect(try await fixture.contents(of: destination.appendingPathComponent("media/clip.mp4")) == Data("MEDIA".utf8))
            #expect(try await fixture.contents(of: destination.appendingPathComponent(Project.thumbnailFilename)) == Data("THUMB".utf8))
            let saved = try await fixture.readPackage(at: destination)
            #expect(saved.manifest?.entries.first?.source == .project(relativePath: "media/clip.mp4"))
        }
    }

    private func makePackage(at url: URL, io: ProjectPackageIO) async throws {
        try await io.perform {
            let media = url.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try Data("MEDIA".utf8).write(to: media.appendingPathComponent("clip.mp4"))
            try Data("THUMB".utf8).write(to: url.appendingPathComponent(Project.thumbnailFilename))
        }
    }

    private func configuredDocument(_ fixture: PackageTestFixture) -> VideoProject {
        let document = fixture.document()
        document.editorViewModel.timeline = Fixtures.timeline()
        document.editorViewModel.mediaManifest.entries = [
            .init(id: "clip", name: "Clip", type: .video, source: .project(relativePath: "media/clip.mp4"), duration: 1),
        ]
        return document
    }
}
