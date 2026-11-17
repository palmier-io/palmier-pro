import Foundation
import Testing
@testable import CompositorPro

@Suite("Editing progress persistence")
struct EditingProgressPersistenceTests {
    private let fm = FileManager.default

    private func makePackageURL() -> URL {
        fm.temporaryDirectory
            .appendingPathComponent("progress-\(UUID().uuidString).\(Project.fileExtension)", isDirectory: true)
    }

    private func makeSnapshot(progress: EditingProgressSummary?) throws -> ProjectPackageSnapshot {
        ProjectPackageSnapshot(
            timeline: try JSONEncoder().encode(ProjectFile(timelines: [Fixtures.timeline()])),
            manifest: nil,
            plans: nil,
            thumbnail: nil,
            chatSessionFiles: [],
            editingProgress: progress
        )
    }

    @Test func progressRoundTripsThroughTheProjectPackage() async throws {
        let bundle = makePackageURL()
        defer { try? fm.removeItem(at: bundle) }

        var progress = EditingProgressSummary()
        progress.phase = "rough-cut"
        progress.completed = ["Imported footage"]
        progress.inProgress = "Trimming intro"
        progress.blocked = ["Missing music bed"]
        progress.next = ["Trim cold open"]
        progress.handoffNote = "Tighten the intro before color"
        progress.recentEdits = [.init(tool: "trim_clip", target: "clip-1", note: nil, at: Date(timeIntervalSince1970: 1_700_000_000))]
        progress.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)

        try VideoProject.writeProjectPackage(try makeSnapshot(progress: progress), to: bundle, sourceURL: nil)

        let progressFile = bundle
            .appendingPathComponent(ChatSessionStore.dirName, isDirectory: true)
            .appendingPathComponent(EditingProgressStore.fileName, isDirectory: false)
        #expect(fm.fileExists(atPath: progressFile.path))

        let loaded = await EditingProgressStore.load(from: bundle)
        #expect(loaded == progress)
    }

    @Test func resavingTheSamePackageKeepsTheLatestProgress() async throws {
        let bundle = makePackageURL()
        defer { try? fm.removeItem(at: bundle) }

        var first = EditingProgressSummary()
        first.phase = "assembly"
        first.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try VideoProject.writeProjectPackage(try makeSnapshot(progress: first), to: bundle, sourceURL: bundle)

        var second = first
        second.phase = "color-grade"
        second.handoffNote = "Match the second scene"
        second.updatedAt = Date(timeIntervalSince1970: 1_700_000_200)
        try VideoProject.writeProjectPackage(try makeSnapshot(progress: second), to: bundle, sourceURL: bundle)

        let loaded = await EditingProgressStore.load(from: bundle)
        #expect(loaded.phase == "color-grade")
        #expect(loaded.handoffNote == "Match the second scene")
    }

    @MainActor
    @Test func progressMetadataChangesMarkTheDocumentDirty() {
        let service = AgentService()
        var changes = 0
        service.onEditingProgressChanged = { changes += 1 }

        service.setHandoffNote("Hand off to color")
        service.setEditingPhase("color-grade")
        service.setNextSteps(["Balance act two"])
        service.recordProgressStep("Rough cut finished")

        #expect(changes == 4)
        #expect(service.editingProgress.handoffNote == "Hand off to color")
        #expect(service.editingProgress.phase == "color-grade")
        #expect(service.editingProgress.next == ["Balance act two"])
        #expect(service.editingProgress.completed == ["Rough cut finished"])
    }
}
