import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Project tool intent admission")
@MainActor
struct ProjectIntentMCPTests {
    @Test func admittedMeasurementDrainsWhileFreshEditsRefuseAndOrdinarySaveCompletes() async throws {
        try await withMeasurement { harness, executor, gate, plan in
            let server = Server(name: "project-intent", version: "1", capabilities: .init(tools: .init(listChanged: false)))
            await MCPService.registerTools(on: server, executor: executor)
            let transports = await InMemoryTransport.createConnectedPair()
            let client = Client(name: "project-intent-tests", version: "1")
            try await server.start(transport: transports.server)
            do {
                _ = try await client.connect(transport: transports.client)
                let undo = UndoManager()
                undo.groupsByEvent = false
                harness.editor.undo.attach(undo)
                let coordinator = harness.editor.projectPackageCoordinator
                let operation = Task {
                    try await client.callTool(name: "plan_edit", arguments: [
                        "action": .string("measure_narration"), "planId": .string(plan.id),
                    ])
                }
                await gate.waitUntilStarted()
                let close = try #require(coordinator.beginClosing())
                do {
                    #expect(!coordinator.canFinishClosing)
                    var saved = false
                    coordinator.enqueueSave { lease in
                        coordinator.finishSave(lease) { saved = true }
                    }
                    #expect(saved)
                    #expect(!coordinator.canFinishClosing)
                    let refused = try await client.callTool(name: "plan_edit", arguments: [
                        "action": .string("update"), "planId": .string(plan.id),
                        "patch": .object(["notes": .string("Late edit")]),
                    ])
                    #expect(refused.isError == true)
                    #expect(harness.editor.editPlans == [plan])
                    #expect(!undo.canUndo)
                    await gate.finish()
                    let result = try await operation.value
                    #expect(result.isError != true)
                    try await coordinator.waitUntilIdle(for: close)
                    #expect(coordinator.canFinishClosing)
                    let measured = try #require(harness.editor.editPlan(id: plan.id))
                    #expect(measured.narrationTiming?.duration.cmTime.seconds == 3)
                    #expect(measured.narrationTiming?.unresolvedBeatIds.isEmpty == true)
                    #expect(undo.canUndo)
                    coordinator.cancelClosing(close)
                    let read = try await client.callTool(name: "plan_edit", arguments: [
                        "action": .string("read"), "planId": .string(plan.id),
                    ])
                    let timing = try #require(try json(read.content)["narrationTiming"] as? [String: Any])
                    #expect(timing["sourceFingerprint"] as? String == measured.narrationTiming?.sourceFingerprint)
                    let undone = try await client.callTool(name: "undo")
                    #expect(undone.isError != true)
                    #expect(harness.editor.editPlans == [plan])
                    #expect(!undo.canUndo)
                    #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
                } catch {
                    operation.cancel()
                    await gate.finish()
                    _ = await operation.result
                    coordinator.cancelClosing(close)
                    throw error
                }
                await client.disconnect()
                await server.stop()
            } catch {
                await client.disconnect()
                await server.stop()
                throw error
            }
        }
    }

    @Test func canceledMeasurementReleasesIntentAfterTerminalFailureWithoutMutationOrUndo() async throws {
        try await withMeasurement { harness, executor, gate, plan in
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let coordinator = harness.editor.projectPackageCoordinator
            let operation = Task {
                await executor.execute(name: "plan_edit", args: ["action": "measure_narration", "planId": plan.id])
            }
            await gate.waitUntilStarted()
            let close = try #require(coordinator.beginClosing())
            #expect(!coordinator.canFinishClosing)
            operation.cancel()
            await gate.finish()
            #expect(await operation.value.isError)
            try await coordinator.waitUntilIdle(for: close)
            #expect(coordinator.canFinishClosing)
            #expect(harness.editor.editPlans == [plan])
            #expect(!undo.canUndo)
            coordinator.cancelClosing(close)
            #expect(!coordinator.isClosing)
        }
    }

    private func withMeasurement(
        _ operation: @MainActor (ToolHarness, ToolExecutor, NarrationTranscriptGate, EditPlan) async throws -> Void
    ) async throws {
        let directory = try await PlanNarrationFixtures.makeAudio()
        do {
            let harness = ToolHarness()
            let audio = harness.addAsset(id: "intent-narration", type: .audio, duration: 3)
            audio.url = directory.appendingPathComponent("voice.wav")
            let plan = EditPlan(name: "Intent narration", timelineId: harness.editor.activeTimelineId,
                fps: harness.editor.timeline.fps, width: harness.editor.timeline.width, height: harness.editor.timeline.height,
                scriptBeats: PlanNarrationFixtures.beats(), narrationIntent: .init(startFrame: 0),
                narration: .init(mediaRef: audio.id))
            try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
            let stored = try #require(harness.editor.editPlan(id: plan.id))
            let gate = NarrationTranscriptGate()
            let service = NarrationTimingService { _, _ in await gate.transcript() }
            let executor = ToolExecutor(editor: harness.editor, narrationTimingService: service)
            try await operation(harness, executor, gate, stored)
        } catch {
            try await PlanNarrationFixtures.remove(directory)
            throw error
        }
        try await PlanNarrationFixtures.remove(directory)
    }

    private func json(_ content: [Tool.Content]) throws -> [String: Any] {
        let text = content.compactMap { item -> String? in
            guard case .text(let text, _, _) = item else { return nil }
            return text
        }.joined()
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
