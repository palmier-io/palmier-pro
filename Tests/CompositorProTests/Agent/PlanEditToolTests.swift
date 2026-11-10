import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Edit plans")
@MainActor
struct PlanEditToolTests {
    @Test func discoveryAdvertisesBothContracts() async throws {
        let harness = ToolHarness()
        let server = Server(name: "plan-edit-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "plan-edit-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let plan = try #require(tools.first { $0.name == "plan_edit" })
            let apply = try #require(tools.first { $0.name == "apply_plan" })
            let planActions = try #require(plan.inputSchema.objectValue?["properties"]?.objectValue?["action"]?.objectValue?["enum"]?.arrayValue)
            #expect(planActions.compactMap(\.stringValue) == ["create", "read", "update", "status", "delete", "review_claims", "measure_narration", "prepare_narration", "prepare_storyboard", "read_storyboard", "review_storyboard_scene", "approve_storyboard", "cancel_production", "revise_storyboard_scene", "reorder_storyboard"])
            let applyRequired = try #require(apply.inputSchema.objectValue?["required"]?.arrayValue)
            #expect(applyRequired.compactMap(\.stringValue) == ["planId"])

            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"),
                "plan": .object([
                    "planId": .string("plan-mcp"),
                    "name": .string("B-roll coverage"),
                    "shots": .array([
                        .object([
                            "shotId": .string("shot-mcp"),
                            "title": .string("Harbor at dusk"),
                            "startFrame": .int(0),
                            "endFrame": .int(120),
                            "candidateURL": .string("https://cdn.example.invalid/harbor.mp4"),
                            "license": .string("CC0 1.0"),
                            "attribution": .string("Harbor by Example."),
                        ]),
                    ]),
                ]),
            ])
            #expect(created.isError != true)

            let approved = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("status"),
                "planId": .string("plan-mcp"),
                "status": .string("approved"),
            ])
            #expect(approved.isError != true)

            let validated = try await client.callTool(name: "apply_plan", arguments: [
                "planId": .string("plan-mcp"),
            ])
            #expect(validated.isError != true)
            let payload = try json(text(validated.content))
            #expect(payload["ready"] as? Bool == false)
            #expect(payload["applied"] as? Bool == false)
            #expect((payload["blockers"] as? [String] ?? []).contains { $0.contains("import_media") })
            #expect(harness.editor.editPlan(id: "plan-mcp")?.status == .approved)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func approvedPlanAppliesAsOneReversibleTimelineChange() async throws {
        let harness = ToolHarness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        var checkpoints = 0
        harness.editor.onProjectCheckpointRequired = { checkpoints += 1 }

        let harnessed = harness.addAsset(id: "asset-ready", type: .video, duration: 8)
        _ = try await harness.runOK("plan_edit", args: Self.createPayload(planId: "plan-undo", mediaRef: harnessed.id))
        _ = try await harness.runOK("plan_edit", args: [
            "action": "status", "planId": "plan-undo", "status": "approved",
        ])
        let before = harness.editor.timeline
        _ = try await harness.runOK("apply_plan", args: ["planId": "plan-undo", "commit": true])
        #expect(harness.editor.editPlan(id: "plan-undo")?.status == .applied)
        #expect(harness.editor.timeline != before)
        #expect(harness.editor.timeline.tracks.flatMap(\.clips).contains { $0.mediaRef == harnessed.id })
        #expect(checkpoints >= 3)

        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(harness.editor.editPlan(id: "plan-undo")?.status == .approved)
        #expect(harness.editor.timeline == before)
    }

    @Test func invalidRequestsDoNotCreatePlansOrUndoEntries() async throws {
        let harness = ToolHarness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        var checkpoints = 0
        harness.editor.onProjectCheckpointRequired = { checkpoints += 1 }

        let cases: [(String, [String: Any], String)] = [
            ("unknown action", ["action": "make"], "must be create"),
            ("unknown nested key", ["action": "create", "plan": ["name": "Bad", "bogus": true]], "unknown field"),
            ("empty title", ["action": "create", "plan": ["name": "   "]], "non-empty"),
            ("inverted frames", ["action": "create", "plan": ["name": "Bad", "shots": [["shotId": "s", "title": "t", "startFrame": 10, "endFrame": 10]]]], "startFrame < endFrame"),
            ("duplicate shot ids", ["action": "create", "plan": ["name": "Bad", "shots": [
                ["shotId": "s", "title": "one", "startFrame": 0, "endFrame": 10],
                ["shotId": "s", "title": "two", "startFrame": 10, "endFrame": 20],
            ]]], "Duplicate plan element id"),
            ("candidate without provenance", ["action": "create", "plan": ["name": "Bad", "shots": [
                ["shotId": "s", "title": "t", "startFrame": 0, "endFrame": 10, "candidateURL": "https://cdn.example.invalid/a.mp4"],
            ]]], "license"),
            ("non-HTTPS candidate", ["action": "create", "plan": ["name": "Bad", "shots": [
                ["shotId": "s", "title": "t", "startFrame": 0, "endFrame": 10, "candidateURL": "http://cdn.example.invalid/a.mp4", "license": "CC0", "attribution": "A"],
            ]]], "HTTPS"),
            ("source span without an end", ["action": "create", "plan": ["name": "Bad", "shots": [
                ["shotId": "s", "title": "t", "startFrame": 0, "endFrame": 10, "sourceStartSeconds": 1.0],
            ]]], "both sourceStartSeconds"),
            ("unknown plan", ["action": "status", "planId": "plan-missing", "status": "approved"], "Unknown planId"),
        ]
        for (index, (name, args, expected)) in cases.enumerated() {
            let result = await harness.runRaw("plan_edit", args: args)
            let message = ToolHarness.textOf(result)
            #expect(result.isError, "case \(index) \(name): \(message)")
            #expect(message.contains(expected), "case \(index) \(name): \(message)")
        }
        #expect(harness.editor.editPlans.isEmpty)
        #expect(!undoManager.canUndo)
        #expect(checkpoints == 0)
    }

    @Test func sourceTooShortIsBlockedBeforePlanStatusOrUndoChanges() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(duration: 1)
        _ = try await harness.runOK("plan_edit", args: Self.createPayload(planId: "short-source", mediaRef: asset.id))
        _ = try await harness.runOK("plan_edit", args: ["action": "status", "planId": "short-source", "status": "approved"])
        let manager = UndoManager()
        harness.editor.undo.attach(manager)
        let before = harness.editor.timeline
        let result = try #require(try await harness.runOK("apply_plan", args: ["planId": "short-source"]) as? [String: Any])
        #expect(result["ready"] as? Bool == false)
        #expect((await harness.runRaw("apply_plan", args: ["planId": "short-source", "commit": true])).isError)
        #expect(harness.editor.editPlan(id: "short-source")?.status == .approved)
        #expect(harness.editor.timeline == before)
        #expect(!manager.canUndo)
    }

    @Test func updatePreservesIdentityAndIgnoresUnchangedPatches() async throws {
        let harness = ToolHarness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        _ = try await harness.runOK("plan_edit", args: Self.createPayload(
            planId: "plan-update",
            shotId: "shot-update",
            mediaRef: "asset-update"
        ))
        let updated = try #require(try await harness.runOK("plan_edit", args: [
            "action": "update",
            "planId": "plan-update",
            "patch": ["notes": "Approved wording only."],
        ]) as? [String: Any])
        #expect(updated["name"] as? String == "Coverage")
        #expect((updated["timelineId"] as? String).map(harness.editor.activeTimelineId.hasPrefix) == true)
        let shots = try #require(updated["shots"] as? [[String: Any]])
        #expect(shots.first?["shotId"] as? String == "shot-update")

        let unchanged = try #require(try await harness.runOK("plan_edit", args: [
            "action": "update",
            "planId": "plan-update",
            "patch": ["notes": "Approved wording only."],
        ]) as? [String: Any])
        #expect(unchanged["noOp"] as? Bool == true)
        undoManager.undo()
        #expect(harness.editor.editPlan(id: "plan-update")?.notes == "")
    }

    @Test func shortPlanPrefixesExpandToStableIds() async throws {
        let harness = ToolHarness()
        _ = try await harness.runOK("plan_edit", args: Self.createPayload(planId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let status = try await harness.runOK("plan_edit", args: [
            "action": "status", "planId": "aaaaaaaa", "status": "approved",
        ]) as? [String: Any]
        #expect(status?["status"] as? String == "approved")
        #expect(status?["planId"] as? String == "aaaaaaaa")
    }

    @Test func applyReportsEveryUnresolvedOrStaleReference() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "base", start: 0, duration: 240)]),
        ]))
        let missing = harness.addAsset(id: "asset-ready", type: .video, duration: 8)
        _ = harness.addAsset(id: "asset-failed", type: .video, duration: 8)
        harness.editor.mediaAssetsById["asset-failed"]?.generationStatus = .failed("test")
        _ = try await harness.runOK("plan_edit", args: [
            "action": "create",
            "plan": [
                "planId": "plan-blocked",
                "name": "Coverage",
                "shots": [
                    ["shotId": "ready", "title": "A", "startFrame": 0, "endFrame": 30, "mediaRef": missing.id],
                    ["shotId": "gone", "title": "B", "startFrame": 30, "endFrame": 60, "mediaRef": "asset-missing"],
                    ["shotId": "broken", "title": "C", "startFrame": 60, "endFrame": 90, "mediaRef": "asset-failed"],
                    [
                        "shotId": "remote", "title": "D", "startFrame": 90, "endFrame": 120,
                        "candidateURL": "https://cdn.example.invalid/d.mp4",
                        "license": "CC0 1.0", "attribution": "D by Example.",
                    ],
                    ["shotId": "wild", "title": "E", "startFrame": 120, "endFrame": 150, "trackId": "track-missing"],
                ],
            ],
        ])
        _ = try await harness.runOK("plan_edit", args: [
            "action": "status", "planId": "plan-blocked", "status": "approved",
        ])
        let validated = try await harness.runOK("apply_plan", args: ["planId": "plan-blocked"]) as? [String: Any]
        #expect(validated?["ready"] as? Bool == false)
        let blockers = try #require(validated?["blockers"] as? [String])
        #expect(blockers.contains { $0.contains("asset-missing") })
        #expect(blockers.contains { $0.contains("failed media") })
        #expect(blockers.contains { $0.contains("import_media") })
        #expect(blockers.contains { $0.contains("track-missing") })

        let failed = await harness.runRaw("apply_plan", args: ["planId": "plan-blocked", "commit": true])
        #expect(failed.isError)
        #expect(ToolHarness.textOf(failed).contains("not ready"))
        #expect(harness.editor.editPlan(id: "plan-blocked")?.status == .approved)
    }

    private static func createPayload(planId: String, shotId: String = "shot-alpha", mediaRef: String? = nil) -> [String: Any] {
        var shot: [String: Any] = ["shotId": shotId, "title": "Harbor at dusk", "startFrame": 0, "endFrame": 120]
        if let mediaRef { shot["mediaRef"] = mediaRef }
        return [
            "action": "create",
            "plan": [
                "planId": planId,
                "name": "Coverage",
                "goal": "Illustrate one claim without covering the speaker.",
                "sections": [
                    ["sectionId": "section-alpha", "title": "Hook", "startFrame": 0, "endFrame": 120],
                ],
                "shots": [shot],
            ],
        ]
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
