import Foundation
import Testing
@testable import CompositorPro

@Suite("Production export uniqueness gate", .serialized)
@MainActor
struct ProductionExportGateTests {
    @Test func approvedProductionRefusesDuplicateVisualBeforeDelivery() async throws {
        try await withProduction(phase: .approved, duplicate: true) { harness, output in
            let undo = UndoManager()
            undo.groupsByEvent = false
            harness.editor.undo.attach(undo)
            let before = harness.editor.timeline
            let result = await harness.runRaw("export_project", args: ["outputPath": output.path])
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("delivery refused"))
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func approvedProductionDeliveriesUniqueOutput() async throws {
        try await withProduction(phase: .approved, duplicate: false) { harness, output in
            let result = try await harness.runOK("export_project", args: ["outputPath": output.path]) as? [String: Any]
            #expect(result?["status"] as? String == "started" || result?["status"] as? String == "queued")
        }
    }

    @Test func canceledProductionKeepsGeneralEditingContract() async throws {
        try await withProduction(phase: .canceled, duplicate: true) { harness, output in
            let result = try await harness.runOK("export_project", args: ["outputPath": output.path]) as? [String: Any]
            #expect(result?["status"] as? String == "started" || result?["status"] as? String == "queued")
        }
    }

    @Test func editExchangeIgnoresProductionVideoDuplicates() async throws {
        try await withProduction(phase: .approved, duplicate: true) { harness, output in
            let result = try await harness.runOK(
                "export_project", args: ["mode": "xml", "outputPath": output.deletingPathExtension().appendingPathExtension("xml").path]
            ) as? [String: Any]
            #expect(result?["status"] as? String == "started" || result?["status"] as? String == "queued")
        }
    }

    private func withProduction(
        phase: ProductionRun.Phase,
        duplicate: Bool,
        _ body: @MainActor (ToolHarness, URL) async throws -> Void
    ) async throws {
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        try Data("second source".utf8).write(to: directory.appendingPathComponent("second.png"))
        let harness = ToolHarness()
        defer { Task { try? await MediaInputIdentityFixtures.remove(directory) } }
        let second = harness.addAsset(id: "second", type: .image, duration: 0)
        second.url = directory.appendingPathComponent("second.png")
        let first = harness.addAsset(id: "source", type: .image, duration: 0)
        first.url = directory.appendingPathComponent("original.png")
        for asset in [first, second] {
            try await asset.prepareInputIdentity()
            harness.editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
        }
        let secondRef = duplicate ? "source" : "second"
        harness.editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: "source", start: 0, duration: 60),
                Fixtures.clip(mediaRef: secondRef, start: 120, duration: 60),
            ]),
        ])
        let revision = String(repeating: "a", count: 64)
        let plan = EditPlan(
            name: "Gate", timelineId: harness.editor.activeTimelineId,
            fps: harness.editor.timeline.fps, width: harness.editor.timeline.width, height: harness.editor.timeline.height
        )
        try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
        // Bypass the plan validator to stage review state directly for the gate fixture.
        harness.editor.editPlans[harness.editor.editPlans.firstIndex { $0.id == plan.id }!].productionRun =
            ProductionRun(phase: phase, storyboardRevision: revision, approvedRevision: phase == .approved ? revision : nil)
        let output = directory.appendingPathComponent("out.mp4")
        try await body(harness, output)
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
    }
}
