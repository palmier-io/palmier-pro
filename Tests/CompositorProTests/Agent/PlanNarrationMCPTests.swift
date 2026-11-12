import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Narration timing MCP")
@MainActor
struct PlanNarrationMCPTests {
    @Test func measuredScenesAndAudioAssembleTogetherPersistAndUndo() async throws {
        try await withClient { client, harness, directory in
            let (tools, _) = try await client.listTools()
            let discovery = try #require(tools.first { $0.name == "plan_edit" })
            let properties = try #require(discovery.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["action"]?.objectValue?["enum"]?.arrayValue?.contains(.string("measure_narration")) == true)
            #expect(properties["plan"]?.objectValue?["properties"]?.objectValue?["scriptBeats"] != nil)
            let baseline = harness.editor.timeline
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let measured = try await client.callTool(name: "plan_edit", arguments: ["action": .string("measure_narration"), "planId": .string("narration-plan")])
            #expect(measured.isError != true)
            #expect(try json(measured.content)["aligned"] as? Bool == true)
            let plan = try #require(harness.editor.editPlan(id: "narration-plan"))
            #expect(plan.narrationTiming?.duration.cmTime.seconds == 3)
            #expect(try plan.resolvedShots().map(\.startFrame) == [30, 75])
            let read = try await client.callTool(name: "plan_edit", arguments: ["action": .string("read"), "planId": .string(plan.id)])
            let shots = try #require(try json(read.content)["shots"] as? [[String: Any]])
            #expect((shots[0]["resolvedTiming"] as? [String: Any])?["startFrame"] as? Int == 30)
            #expect((shots[1]["resolvedTiming"] as? [String: Any])?["endFrame"] as? Int == 120)
            #expect(shots[0]["startFrame"] as? Int == 0)
            let repeated = try await client.callTool(name: "plan_edit", arguments: ["action": .string("measure_narration"), "planId": .string(plan.id)])
            #expect(try json(repeated.content)["noOp"] as? Bool == true)
            #expect(harness.editor.timeline == baseline)
            let package = try await Task.detached {
                try EditPlanStore.writePackageFile(EditPlanStore.encode([plan]), to: directory, sourceURL: nil)
                return try EditPlanStore.readPackageFile(at: directory)
            }.value
            #expect(!package.unreadable)
            let persisted = try #require(package.plans.first)
            #expect(persisted.scriptBeats == plan.scriptBeats)
            #expect(persisted.narrationIntent == plan.narrationIntent)
            #expect(persisted.narration == plan.narration)
            #expect(persisted.narrationRevision == plan.narrationRevision)
            #expect(persisted.narrationTiming == plan.narrationTiming)
            #expect(persisted.shots == plan.shots)
            #expect(try persisted.resolvedShots() == plan.resolvedShots())

            _ = try await client.callTool(name: "plan_edit", arguments: ["action": .string("status"), "planId": .string(plan.id), "status": .string("approved")])
            let preview = try await client.callTool(name: "apply_plan", arguments: ["planId": .string(plan.id)])
            #expect(try json(preview.content)["ready"] as? Bool == true)
            let assembled = try await client.callTool(name: "apply_plan", arguments: ["planId": .string(plan.id), "commit": .bool(true)])
            #expect(assembled.isError != true)
            let clips = harness.editor.timeline.tracks.flatMap(\.clips)
            #expect(clips.count == 3)
            #expect(clips.first { $0.mediaRef == "first-image" }?.startFrame == 30)
            #expect(clips.first { $0.mediaRef == "first-image" }?.durationFrames == 45)
            #expect(clips.first { $0.mediaRef == "second-image" }?.startFrame == 75)
            #expect(clips.first { $0.mediaRef == "narration-audio" }?.durationFrames == 90)
            let timelineRead = try await client.callTool(name: "get_timeline")
            #expect(try text(timelineRead.content).contains("narration-audio"))
            let repeatedAssembly = try await client.callTool(name: "apply_plan", arguments: ["planId": .string(plan.id), "commit": .bool(true)])
            #expect(try json(repeatedAssembly.content)["noOp"] as? Bool == true)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == baseline)
            #expect(harness.editor.editPlan(id: plan.id)?.status == .approved)
            _ = try await client.callTool(name: "undo")
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.editPlan(id: plan.id)?.narrationTiming == nil)
            #expect(!undo.canUndo)
        }
    }

    @Test func pronunciationChangeInvalidatesTimingAndCannotUseOldAudio() async throws {
        try await withClient { client, harness, _ in
            _ = try await client.callTool(name: "plan_edit", arguments: ["action": .string("measure_narration"), "planId": .string("narration-plan")])
            let before = try #require(harness.editor.editPlan(id: "narration-plan"))
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            var beats = PlanNarrationFixtures.beats()
            beats[0].spokenText = "Different pronunciation."
            let revised = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string(before.id), "patch": .object(["scriptBeats": try Value(beats)]),
            ])
            #expect(revised.isError != true)
            #expect(harness.editor.editPlan(id: before.id)?.narrationTiming == nil)
            #expect(harness.editor.editPlan(id: before.id)?.narrationRevision != before.narrationRevision)
            let measured = try await client.callTool(name: "plan_edit", arguments: ["action": .string("measure_narration"), "planId": .string(before.id)])
            #expect(try json(measured.content)["aligned"] as? Bool == false)
            #expect(harness.editor.editPlan(id: before.id)?.narrationTiming?.unresolvedBeatIds == ["first-beat", "second-beat"])
            _ = try await client.callTool(name: "plan_edit", arguments: ["action": .string("status"), "planId": .string(before.id), "status": .string("approved")])
            let timeline = harness.editor.timeline
            let blocked = try await client.callTool(name: "apply_plan", arguments: ["planId": .string(before.id), "commit": .bool(true)])
            #expect(blocked.isError == true)
            #expect(harness.editor.timeline == timeline)
            _ = try await client.callTool(name: "undo")
            _ = try await client.callTool(name: "undo")
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.editPlan(id: before.id) == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func changedSourceAndUnknownInputsFailWithoutMutation() async throws {
        try await withClient { client, harness, directory in
            _ = try await client.callTool(name: "plan_edit", arguments: ["action": .string("measure_narration"), "planId": .string("narration-plan")])
            _ = try await client.callTool(name: "plan_edit", arguments: ["action": .string("status"), "planId": .string("narration-plan"), "status": .string("approved")])
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let before = harness.editor.timeline
            let url = directory.appendingPathComponent("voice.wav")
            try await Task.detached { try Data("changed".utf8).write(to: url) }.value
            let blocked = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("narration-plan"), "commit": .bool(true)])
            #expect(blocked.isError == true)
            #expect(harness.editor.timeline == before)
            let invalid = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string("narration-plan"),
                "patch": .object(["narration": .object(["mediaRef": .string("narration-audio"), "startFrame": .int(0), "guessedDuration": .int(90)])]),
            ])
            #expect(invalid.isError == true)
            #expect(!undo.canUndo)
        }
    }

    private func withClient(_ operation: @MainActor (Client, ToolHarness, URL) async throws -> Void) async throws {
        let directory = try await PlanNarrationFixtures.makeAudio()
        let harness = ToolHarness()
        let audio = harness.addAsset(id: "narration-audio", type: .audio, duration: 3)
        audio.url = directory.appendingPathComponent("voice.wav")
        harness.addAsset(id: "first-image", type: .image)
        harness.addAsset(id: "second-image", type: .image)
        let service = NarrationTimingService { _, _ in PlanNarrationFixtures.transcript() }
        let executor = ToolExecutor(editor: harness.editor, narrationTimingService: service)
        let server = Server(name: "narration-test", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "narration-test-client", version: "1")
        do {
            try await server.start(transport: transports.server)
            _ = try await client.connect(transport: transports.client)
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"), "plan": .object([
                    "planId": .string("narration-plan"), "name": .string("Measured explainer"),
                    "scriptBeats": try Value(PlanNarrationFixtures.beats()),
                    "narrationIntent": .object(["startFrame": .int(30)]),
                    "narration": .object(["mediaRef": .string(audio.id)]),
                    "shots": .array(["first", "second"].map { name in .object([
                        "shotId": .string("\(name)-scene"), "title": .string(name), "startFrame": .int(0), "endFrame": .int(10),
                        "mediaRef": .string("\(name)-image"),
                        "narrationLink": .object(["firstBeatId": .string("\(name)-beat"), "lastBeatId": .string("\(name)-beat")]),
                    ]) }),
                ]),
            ])
            let message = try text(created.content)
            try #require(created.isError != true, "\(message)")
            try await operation(client, harness, directory)
        } catch {
            await server.stop()
            await client.disconnect()
            try await PlanNarrationFixtures.remove(directory)
            throw error
        }
        await server.stop()
        await client.disconnect()
        try await PlanNarrationFixtures.remove(directory)
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for block in content { if case .text(let text, _, _) = block { return text } }
        throw CocoaError(.coderReadCorrupt)
    }

    private func json(_ content: [Tool.Content]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any])
    }
}
