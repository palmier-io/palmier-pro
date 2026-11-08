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
            try await document.saveBeforeClosing()
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
            await #expect(throws: CocoaError.self) { try await document.saveBeforeClosing() }
            let coordinator = document.editorViewModel.projectPackageCoordinator
            #expect(!coordinator.isClosing)
            try await coordinator.withMutation { _ in }
            let saved = try await fixture.readPackage()
            #expect(saved.manifest == original.manifest)
            #expect(saved.projectFile.timelines == original.projectFile.timelines)
        }
    }
}
