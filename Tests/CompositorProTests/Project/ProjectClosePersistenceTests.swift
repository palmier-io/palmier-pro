import Foundation
import Testing
@testable import CompositorPro

@Suite("Project close persistence", .serialized)
@MainActor
struct ProjectClosePersistenceTests {
    @Test func finalSavePersistsSnapshotWhenDocumentIsNotMarkedEdited() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            document.editorViewModel.timeline = Fixtures.timeline(tracks: [
                Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)]),
            ])
            try await savePackageTestDocument(document)
            document.editorViewModel.timeline.tracks[0].clips[0].durationFrames = 90
            #expect(!document.isDocumentEdited)
            let close = try #require(document.beginClosing())
            defer { document.editorViewModel.projectPackageCoordinator.cancelClosing(close) }
            try await document.saveBeforeClosing(using: close)
            let saved = try await fixture.readPackage()
            #expect(saved.projectFile.timelines.first?.tracks.first?.clips.count == 1)
            #expect(saved.projectFile.timelines.first?.tracks.first?.clips.first?.durationFrames == 90)
        }
    }

    @Test func failedFinalSaveReopensAdmissionAndPreservesLastGoodPackage() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            document.editorViewModel.mediaManifest.entries = [
                .init(id: "media", name: "Media", type: .video, source: .project(relativePath: "media/proof.mp4"), duration: 1),
            ]
            try await savePackageTestDocument(document)
            let original = try await fixture.readPackage()
            document.editorViewModel.mediaManifest.entries[0].duration = .nan
            document.editorViewModel.timeline.name = "Unsaved"
            let close = try #require(document.beginClosing())
            await #expect(throws: CocoaError.self) { try await document.saveBeforeClosing(using: close) }
            let coordinator = document.editorViewModel.projectPackageCoordinator
            #expect(coordinator.isClosing)
            coordinator.cancelClosing(close)
            #expect(!coordinator.isClosing)
            try await coordinator.withMutation { _ in }
            let saved = try await fixture.readPackage()
            #expect(saved.manifest == original.manifest)
            #expect(saved.projectFile.timelines == original.projectFile.timelines)
        }
    }

    @Test func failedBorrowedSaveKeepsOtherCloseOwnerAndLastGoodPackage() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            try await savePackageTestDocument(document)
            let original = try await fixture.readPackage()
            let coordinator = document.editorViewModel.projectPackageCoordinator
            let failing = try #require(document.beginClosing())
            let quit = try #require(document.beginClosing())
            defer {
                coordinator.cancelClosing(failing)
                coordinator.cancelClosing(quit)
            }
            document.editorViewModel.mediaManifest.entries = [
                .init(id: "invalid", name: "Invalid", type: .video,
                    source: .project(relativePath: "media/invalid.mp4"), duration: .nan),
            ]
            await #expect(throws: CocoaError.self) { try await document.saveBeforeClosing(using: failing) }
            try coordinator.validate(failing)
            coordinator.cancelClosing(failing)
            try coordinator.validate(quit)
            #expect(coordinator.isClosing)
            #expect(!coordinator.isClosed)
            #expect(throws: CancellationError.self) { try coordinator.admitIntent() }
            let saved = try await fixture.readPackage()
            #expect(saved.projectFile.timelines == original.projectFile.timelines)
            #expect(saved.manifest == original.manifest)
            coordinator.cancelClosing(quit)
            #expect(!coordinator.isClosing)
            await coordinator.waitUntilIdle()
        }
    }
}
