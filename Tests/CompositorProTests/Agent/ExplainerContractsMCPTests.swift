import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Explainer tool contracts")
@MainActor
struct ExplainerContractsMCPTests {
    @Test func briefAndCueSchemasMatchCreateUpdateAndDomainRules() async throws {
        try await withClient { client, _ in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "plan_edit" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let create = try #require(properties["plan"]?.objectValue?["properties"]?.objectValue)
            let update = try #require(properties["patch"]?.objectValue?["properties"]?.objectValue)
            #expect(create["brief"] == update["brief"])
            #expect(create["soundCues"] == update["soundCues"])
            let realism = try #require(create["brief"]?.objectValue?["properties"]?.objectValue?["realism"]?.objectValue?["enum"]?.arrayValue)
            #expect(realism == PlanBrief.Realism.allCases.map { .string($0.rawValue) })
            let cue = try #require(create["soundCues"]?.objectValue?["items"]?.objectValue)
            #expect(cue["required"]?.arrayValue?.contains(.string("cueId")) == true)
            let anchor = try #require(cue["properties"]?.objectValue?["anchorFrame"]?.objectValue)
            #expect(anchor["maximum"]?.intValue == maxFrameArg - 1)
        }
    }

    @Test(arguments: PlanBrief.Realism.allCases)
    func briefAndCuesRoundTripThroughMCP(realism: PlanBrief.Realism) async throws {
        try await withClient { client, harness in
            let cue: Value = .object([
                "cueId": .string("sound-opening"), "role": .string("ambience"),
                "purpose": .string("Establish the room."), "anchorFrame": .int(0),
                "durationSeconds": .double(0.05),
            ])
            let brief: Value = .object(["realism": .string(realism.rawValue), "durationSeconds": .double(0.05)])
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"), "plan": .object([
                    "planId": .string("brief-cue-plan"), "name": .string("Sound purpose"),
                    "brief": brief, "soundCues": .array([cue]),
                ]),
            ])
            #expect(created.isError != true)
            let original = try #require(harness.editor.editPlan(id: "brief-cue-plan"))
            #expect(original.brief?.realism == realism)
            #expect(original.soundCues?.first?.cueId == "sound-opening")
            let repeated = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string(original.id),
                "patch": .object(["brief": brief, "soundCues": .array([cue])]),
            ])
            #expect(repeated.isError != true)
            #expect(try json(repeated.content)["noOp"] as? Bool == true)
            let read = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("read"), "planId": .string(original.id),
            ])
            #expect(try json(read.content)["brief"] as? [String: Any] != nil)
            let restored = try #require(EditPlanStore.decode(EditPlanStore.encode(harness.editor.editPlans)).first)
            #expect(restored.brief == original.brief)
            #expect(restored.soundCues == original.soundCues)
        }
    }

    @Test(arguments: [
        ["role": Value.string("sfx"), "purpose": .string("Close the door.")],
        ["cueId": Value.string("cue"), "role": .string("sfx"), "purpose": .string("Close the door."), "anchorFrame": .int(maxFrameArg)],
        ["cueId": Value.string("cue"), "role": .string("sfx"), "purpose": .string("Close the door."), "anchorFrame": .int(Int.max)],
    ])
    func invalidCueLeavesPlanAndUndoUnchangedThroughMCP(cue: [String: Value]) async throws {
        try await withClient { client, harness in
            let undo = UndoManager()
            undo.groupsByEvent = false
            harness.editor.undo.attach(undo)
            let result = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"), "plan": .object([
                    "planId": .string("invalid-cue-plan"), "name": .string("Invalid cue"),
                    "soundCues": .array([.object(cue)]),
                ]),
            ])
            #expect(result.isError == true)
            #expect(harness.editor.editPlans.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func discoveryDescribesAssemblyImportAndRequestedRuntime() async throws {
        try await withClient { client, _ in
            let (tools, _) = try await client.listTools()
            let apply = try #require(tools.first { $0.name == "apply_plan" })
            #expect(apply.description?.contains("assembles") == true)
            #expect(apply.description?.contains("no timeline edits") == false)
            let commit = try #require(apply.inputSchema.objectValue?["properties"]?.objectValue?["commit"]?.objectValue?["description"]?.stringValue)
            #expect(commit.contains("assemble"))
            let importer = try #require(tools.first { $0.name == "import_media" })
            #expect(importer.description?.contains("Lottie") == true)
            #expect(importer.description?.contains("5 GiB") == true)
            let mime = try #require(importer.inputSchema.objectValue?["properties"]?.objectValue?["source"]?.objectValue?["properties"]?.objectValue?["mimeType"]?.objectValue?["description"]?.stringValue)
            #expect(mime.contains("application/vnd.lottie+json"))
            #expect(mime.contains("audio/aiff"))
            #expect(AgentInstructions.serverInstructions.contains("Honor the requested duration and format"))
        }
    }

    @Test func approvedPlanAssemblesOnceAndUndoesThroughMCP() async throws {
        try await withClient { client, harness in
            let asset = harness.addAsset(id: "contract-asset", duration: 8)
            let baseline = harness.editor.timeline
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"),
                "plan": .object([
                    "planId": .string("contract-plan"), "name": .string("Coverage"),
                    "shots": .array([.object([
                        "shotId": .string("contract-shot"), "title": .string("Harbor"),
                        "startFrame": .int(0), "endFrame": .int(120),
                        "mediaRef": .string(asset.id),
                    ])]),
                ]),
            ])
            #expect(created.isError != true)
            let approved = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("status"), "planId": .string("contract-plan"), "status": .string("approved"),
            ])
            #expect(approved.isError != true)
            let undo = UndoManager()
            harness.editor.undo.attach(undo)

            let preview = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("contract-plan")])
            #expect(try json(preview.content)["ready"] as? Bool == true)
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)

            let arguments: [String: Value] = ["planId": .string("contract-plan"), "commit": .bool(true)]
            let applied = try await client.callTool(name: "apply_plan", arguments: arguments)
            #expect(applied.isError != true)
            #expect(try json(applied.content)["applied"] as? Bool == true)
            let clips = harness.editor.timeline.tracks.flatMap(\.clips)
            #expect(clips.filter { $0.mediaRef == asset.id }.count == 1)
            let assembled = harness.editor.timeline
            let repeated = try await client.callTool(name: "apply_plan", arguments: arguments)
            #expect(try json(repeated.content)["noOp"] as? Bool == true)
            #expect(harness.editor.timeline == assembled)

            let read = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("read"), "planId": .string("contract-plan"),
            ])
            #expect(try json(read.content)["status"] as? String == "applied")
            let timeline = try await client.callTool(name: "get_timeline")
            #expect(try text(timeline.content).contains(try #require(clips.first?.id).prefix(8)))
            let undone = try await client.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(harness.editor.timeline == baseline)
            #expect(harness.editor.editPlan(id: "contract-plan")?.status == .approved)
            #expect(!undo.canUndo)
        }
    }

    @Test func invalidPlanAndUnsupportedMIMELeaveStateUnchangedThroughMCP() async throws {
        try await withClient { client, harness in
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let baseline = harness.editor.timeline
            let invalid = try await client.callTool(name: "apply_plan", arguments: [
                "planId": .string("missing"), "commit": .bool(true),
            ])
            #expect(invalid.isError == true)
            harness.editor.projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).compositorpro")
            let unsupported = try await client.callTool(name: "import_media", arguments: [
                "source": .object(["bytes": .string("e30="), "mimeType": .string("application/unknown")]),
            ])
            #expect(unsupported.isError == true)
            #expect(try text(unsupported.content).contains("application/vnd.lottie+json"))
            #expect(harness.editor.timeline == baseline)
            #expect(harness.editor.mediaAssets.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func assemblyReceiptMapsShotsToPlacedClipsThroughMCP() async throws {
        try await withClient { client, harness in
            let first = harness.addAsset(id: "mapping-a", duration: 8)
            let second = harness.addAsset(id: "mapping-b", duration: 8)
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"),
                "plan": .object([
                    "name": .string("Mapped"),
                    "shots": .array([
                        .object([
                            "shotId": .string("shot-open"), "title": .string("Open"),
                            "startFrame": .int(0), "endFrame": .int(60),
                            "mediaRef": .string(first.id),
                        ]),
                        .object([
                            "shotId": .string("shot-close"), "title": .string("Close"),
                            "startFrame": .int(60), "endFrame": .int(120),
                            "mediaRef": .string(second.id),
                        ]),
                    ]),
                ]),
            ])
            #expect(created.isError != true)
            let planId = try #require(json(created.content)["planId"] as? String)
            _ = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("status"), "planId": .string(planId), "status": .string("approved"),
            ])
            let applied = try await client.callTool(name: "apply_plan", arguments: [
                "planId": .string(planId), "commit": .bool(true),
            ])
            #expect(applied.isError != true)
            let receipt = try json(applied.content)
            let receiptText = try text(applied.content)
            #expect(receipt["applied"] as? Bool == true, "receipt=\(receiptText)")
            let rows = try #require(receipt["shotAssembly"] as? [[String: Any]], "receipt=\(receiptText)")
            let clips = harness.editor.timeline.tracks.flatMap(\.clips)
            for shotId in ["shot-open", "shot-close"] {
                let row = try #require(rows.first { ($0["shotId"] as? String) == shotId })
                let clipIDs = try #require(row["clipIds"] as? [String])
                let expectedStart = shotId == "shot-open" ? 0 : 60
                #expect(!clipIDs.isEmpty, "row=\(row)")
                // MCP receipts shorten clip ids to stable prefixes.
                #expect(clipIDs.allSatisfy { id in clips.contains { $0.id.hasPrefix(id) } }, "row=\(row) actual=\(clips.map(\.id))")
                let mapped = clips.filter { clip in clipIDs.contains { clip.id.hasPrefix($0) } }
                #expect(!mapped.isEmpty)
                #expect(mapped.allSatisfy { $0.startFrame == expectedStart }, "row=\(row)")
            }
        }
    }

    @Test func productionFindingsAreInspectableThroughMCP() async throws {
        try await withClient { client, harness in
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"), "plan": .object([
                    "planId": .string("review-findings-plan"), "name": .string("Review findings"),
                ]),
            ])
            #expect(created.isError != true)
            let planId = try #require(json(created.content)["planId"] as? String)
            let storedPlan = harness.editor.editPlan(id: planId)
            let plan = try #require(storedPlan)
            var run = ProductionRun(storyboardRevision: String(repeating: "a", count: 64))
            let finding = ProductionRun.Finding(id: "review-finding", severity: .error, kind: "missingMedia", message: "Restore the selected source.", fix: "import_media")
            run.reviewFindings = [finding]
            try harness.editor.commitProductionRun(run, plan: plan, actionName: "Seed review")
            let read = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("read"), "planId": .string(planId),
            ])
            #expect(read.isError != true)
            let production = try #require(json(read.content)["productionRun"] as? [String: Any])
            let findings = try #require(production["reviewFindings"] as? [[String: Any]])
            #expect(findings.count == 1)
            #expect(findings.first?["id"] as? String == finding.id)
            #expect(findings.first?["kind"] as? String == finding.kind)
            #expect(findings.first?["severity"] as? String == "error")
            #expect(harness.editor.editPlan(id: planId)?.productionRun?.reviewFindings == [finding])
        }
    }

    @Test func shotRejectionsPersistAndUndoThroughMCP() async throws {
        try await withClient { client, harness in
            let rejection: Value = .object([
                "candidateRef": .string("stock:fixture:wrong-shot"), "reason": .string("wrong_action"),
                "evidence": .string("Inspected frames show a closed door, not the requested door close."),
            ])
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"), "plan": .object([
                    "planId": .string("door-plan"), "name": .string("Door close"), "shots": .array([.object([
                        "shotId": .string("door-shot"), "title": .string("Door closes"),
                        "startFrame": .int(0), "endFrame": .int(60), "rejections": .array([rejection]),
                        "requirement": .object(["narrativePurpose": .string("End the scene."), "action": .string("Door closes")]),
                    ])]),
                ]),
            ])
            #expect(created.isError != true)
            let planId = try #require(json(created.content)["planId"] as? String)
            let storedPlan = harness.editor.editPlan(id: planId)
            let original = try #require(storedPlan)
            let undo = UndoManager()
            undo.groupsByEvent = false
            harness.editor.undo.attach(undo)
            let patch: [String: Value] = [
                "action": .string("update"), "planId": .string(planId), "patch": .object([
                    "shots": .array([.object([
                        "shotId": .string("door-shot"), "title": .string("Door closes"),
                        "startFrame": .int(0), "endFrame": .int(60), "rejections": .array([]),
                        "requirement": .object(["narrativePurpose": .string("End the scene."), "action": .string("Door closes")]),
                    ])]),
                ]),
            ]
            let updated = try await client.callTool(name: "plan_edit", arguments: patch)
            #expect(updated.isError != true)
            #expect(harness.editor.editPlan(id: planId)?.shots.first?.rejections.isEmpty == true)
            let repeated = try await client.callTool(name: "plan_edit", arguments: patch)
            #expect(try json(repeated.content)["noOp"] as? Bool == true)
            let undone = try await client.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(harness.editor.editPlan(id: planId) == original)
            #expect(!undo.canUndo)
            let read = try await client.callTool(name: "plan_edit", arguments: ["action": .string("read"), "planId": .string(planId)])
            let rows = try #require(json(read.content)["shots"] as? [[String: Any]])
            #expect((rows.first?["rejections"] as? [[String: Any]])?.count == 1)
            let restored = try #require(EditPlanStore.decode(EditPlanStore.encode(harness.editor.editPlans)).first)
            #expect(restored.shots == original.shots)
        }
    }

    private func withClient(_ operation: @MainActor (Client, ToolHarness) async throws -> Void) async throws {
        let harness = ToolHarness()
        let server = Server(name: "explainer-contracts", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "explainer-contract-tests", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await operation(client, harness)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func text(_ blocks: [Tool.Content]) throws -> String {
        for block in blocks { if case .text(let text, _, _) = block { return text } }
        throw CocoaError(.coderReadCorrupt)
    }

    private func json(_ blocks: [Tool.Content]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(blocks).utf8)) as? [String: Any])
    }
}
