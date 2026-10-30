import Foundation
import Testing
@testable import PalmierPro

@Suite("Project close persistence", .serialized)
@MainActor
struct ProjectClosePersistenceTests {
    @Test func finalSavePersistsSnapshotWhenDocumentIsNotMarkedEdited() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-close-\(UUID().uuidString).palmier", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }

        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        document.editorViewModel.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)]),
        ])

        document.save(to: package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
            if let error { Issue.record(error) }
        }
        document.editorViewModel.timeline.tracks[0].clips[0].durationFrames = 90
        #expect(!document.isDocumentEdited)
        try await document.saveBeforeClosing()

        let saved = try VideoProject.readProjectPackage(at: package)
        #expect(saved.projectFile.timelines.first?.tracks.first?.clips.count == 1)
        #expect(saved.projectFile.timelines.first?.tracks.first?.clips.first?.durationFrames == 90)
    }
}
