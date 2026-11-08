import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Storyboard MCP")
@MainActor
struct StoryboardMCPTests {
    @Test func discoveryIncludesRevisionBoundReviewAndFullInspectionContract() async throws {
        try await withClient { client, _, _ in
            let (tools, _) = try await client.listTools()
            let plan = try #require(tools.first { $0.name == "plan_edit" })
            let properties = try #require(plan.inputSchema.objectValue?["properties"]?.objectValue)
            let actions = try #require(properties["action"]?.objectValue?["enum"]?.arrayValue)
            #expect(actions.contains(.string("prepare_storyboard")))
            #expect(actions.contains(.string("approve_storyboard")))
            #expect(properties["coverage"]?.objectValue?["description"]?.stringValue?.contains("sparse frames") == true)
            #expect(properties["evidence"]?.objectValue?["description"]?.stringValue?.contains("Not an automatic detector") == true)
        }
    }

    @Test func inspectionApprovalPersistenceAndUndoShareOneRun() async throws {
        try await withClient { client, harness, _ in
            try await createPlan(client)
            let baseline = harness.editor.timeline
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let prepared = try await board(client, "prepare_storyboard")
            #expect(prepared["phase"] as? String == "awaiting_storyboard_approval")
            #expect((prepared["blockers"] as? [String])?.contains("scene:unresolved_face_and_similarity_inspection") == true)
            let repeated = try await board(client, "prepare_storyboard")
            #expect(repeated["noOp"] as? Bool == true)
            let refused = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("approve_storyboard"), "planId": .string("board"),
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)),
            ])
            #expect(refused.isError == true)
            let inspected = try await inspect(client, prepared: prepared)
            #expect((inspected["blockers"] as? [String])?.isEmpty == true)
            let reviewRepeat = try await inspect(client, prepared: prepared)
            #expect(reviewRepeat["noOp"] as? Bool == true)
            undo.removeAllActions()
            let approved = try await approve(client, prepared: prepared)
            #expect(approved["canProduce"] as? Bool == true)
            let stored = try #require(harness.editor.editPlan(id: "board"))
            let restored = try await roundTrip(stored)
            #expect(restored.productionRun == stored.productionRun)
            #expect(restored.shots.first?.license == "CC0")
            #expect(restored.shots.first?.attribution == "Original licensed source")
            let planRead = try await board(client, "read")
            let run = try #require(planRead["productionRun"] as? [String: Any])
            #expect(run["approvedRevision"] as? String == prepared["storyboardRevision"] as? String)
            let retry = try await approve(client, prepared: prepared)
            #expect(retry["noOp"] as? Bool == true)
            let undone = try await client.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(harness.editor.editPlan(id: "board")?.productionRun?.phase == .awaitingStoryboardApproval)
            #expect(harness.editor.editPlan(id: "board")?.status == .proposed)
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test func copiedSourcesBlockWholeBoardWithoutEdits() async throws {
        try await withClient { client, harness, directory in
            let alias = harness.addAsset(id: "copy", type: .image)
            alias.url = directory.appendingPathComponent("renamed.png")
            try await alias.prepareInputIdentity()
            harness.editor.mediaManifest.entries.append(alias.toManifestEntry(projectURL: nil))
            try await createPlan(client, duplicate: true)
            let prepared = try await board(client, "prepare_storyboard")
            let report = try #require(prepared["visualIdentity"] as? [String: Any])
            let conflicts = try #require(report["conflicts"] as? [[String: Any]])
            #expect(conflicts.count == 1)
            #expect((conflicts.first?["occurrences"] as? [[String: Any]])?.count == 2)
            let baseline = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let result = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("approve_storyboard"), "planId": .string("board"),
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)),
            ])
            #expect(result.isError == true)
            #expect(harness.editor.editPlans == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: [ClipType.image, .video])
    func approvedIntentSurvivesMeasuredTimingAndAssemblesOnceThroughMCP(type: ClipType) async throws {
        let directory = try await PlanNarrationFixtures.makeAudio()
        do {
            let service = NarrationTimingService { _, _ in PlanNarrationFixtures.transcript() }
            try await withClient(timingService: service, type: type) { client, harness, _ in
                let audio = harness.addAsset(id: "narration", type: .audio, duration: 3)
                audio.url = directory.appendingPathComponent("voice.wav")
                harness.editor.mediaManifest.entries.append(audio.toManifestEntry(projectURL: nil))
                try await createPlan(client)
                let changed = try await client.callTool(name: "plan_edit", arguments: [
                    "action": .string("update"), "planId": .string("board"), "patch": .object([
                        "scriptBeats": try Value(PlanNarrationFixtures.beats()),
                        "narration": .object(["mediaRef": .string("narration"), "startFrame": .int(0)]),
                        "shots": .array([.object(["shotId": .string("scene"), "title": .string("Scene"),
                            "startFrame": .int(0), "endFrame": .int(60), "mediaRef": .string("source"),
                            "license": .string("CC0"), "attribution": .string("Original licensed source"),
                            "narrationLink": .object(["firstBeatId": .string("first-beat"), "lastBeatId": .string("second-beat")])])]),
                    ]),
                ])
                #expect(changed.isError != true)
                let prepared = try await board(client, "prepare_storyboard")
                _ = try await inspect(client, prepared: prepared)
                _ = try await approve(client, prepared: prepared)
                let measured = try await client.callTool(name: "plan_edit", arguments: ["action": .string("measure_narration"), "planId": .string("board")])
                #expect(measured.isError != true)
                let current = try await board(client, "read_storyboard")
                #expect(current["storyboardRevision"] as? String == prepared["storyboardRevision"] as? String)
                #expect(current["canProduce"] as? Bool == true)
                let measuredCard = try #require((current["cards"] as? [[String: Any]])?.first)
                #expect(measuredCard["timing"] as? String == "measured")
                #expect((measuredCard["resolvedTiming"] as? [String: Any])?["endFrame"] as? Int == 90)
                #expect(measuredCard["playbackSourceFrames"] as? [Int] == [0, 90])
                if type == .video { #expect(measuredCard["inspectionSourceSpan"] as? [Double] == [0, 5]) }
                let undo = UndoManager()
                harness.editor.undo.attach(undo)
                let baseline = harness.editor.timeline
                let assembled = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("board"), "commit": .bool(true)])
                #expect(assembled.isError != true)
                let clips = harness.editor.timeline.tracks.flatMap(\.clips)
                #expect(clips.count == 2)
                #expect(clips.allSatisfy { $0.durationFrames == 90 })
                #expect(Set(clips.map(\.mediaRef)) == ["source", "narration"])
                let repeated = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("board"), "commit": .bool(true)])
                #expect(try json(repeated)["noOp"] as? Bool == true)
                let readback = try await client.callTool(name: "get_timeline")
                #expect(readback.isError != true)
                _ = try await client.callTool(name: "undo")
                #expect(harness.editor.timeline == baseline)
                #expect(harness.editor.editPlan(id: "board")?.productionRun?.phase == .approved)
                #expect(!undo.canUndo)
            }
        } catch {
            try await PlanNarrationFixtures.remove(directory)
            throw error
        }
        try await PlanNarrationFixtures.remove(directory)
    }

    @Test(arguments: [2.0, 3.0])
    func measuredSourceSpanMustMatchBeforeReadinessAndAssembly(sourceDuration: Double) async throws {
        let directory = try await PlanNarrationFixtures.makeAudio()
        do {
            let service = NarrationTimingService { _, _ in PlanNarrationFixtures.transcript() }
            try await withClient(timingService: service, type: .video) { client, harness, _ in
                let audio = harness.addAsset(id: "narration", type: .audio, duration: 3)
                audio.url = directory.appendingPathComponent("voice.wav")
                harness.editor.mediaManifest.entries.append(audio.toManifestEntry(projectURL: nil))
                let result = try await client.callTool(name: "plan_edit", arguments: [
                    "action": .string("create"), "plan": .object([
                        "planId": .string("board"), "name": .string("Measured source"),
                        "scriptBeats": try Value(PlanNarrationFixtures.beats()),
                        "narration": .object(["mediaRef": .string("narration"), "startFrame": .int(0)]),
                        "shots": .array([.object([
                            "shotId": .string("scene"), "title": .string("Scene"), "startFrame": .int(0),
                            "endFrame": .int(Int(sourceDuration * 30)), "mediaRef": .string("source"),
                            "sourceStartSeconds": .double(1), "sourceEndSeconds": .double(1 + sourceDuration),
                            "license": .string("CC0"), "attribution": .string("Original licensed source"),
                            "narrationLink": .object(["firstBeatId": .string("first-beat"), "lastBeatId": .string("second-beat")]),
                        ])]),
                    ]),
                ])
                #expect(result.isError != true)
                let prepared = try await board(client, "prepare_storyboard")
                _ = try await inspect(client, prepared: prepared)
                _ = try await approve(client, prepared: prepared)
                let measured = try await client.callTool(name: "plan_edit", arguments: ["action": .string("measure_narration"), "planId": .string("board")])
                #expect(measured.isError != true)
                let current = try await board(client, "read_storyboard")
                let card = try #require((current["cards"] as? [[String: Any]])?.first)
                #expect(current["storyboardRevision"] as? String == prepared["storyboardRevision"] as? String)
                #expect(card["inspectionSourceSpan"] as? [Double] == [1, 1 + sourceDuration])
                #expect(card["inspection"] != nil)
                let undo = UndoManager()
                harness.editor.undo.attach(undo)
                let baseline = harness.editor.timeline
                let plans = harness.editor.editPlans
                let readiness = try json(try await client.callTool(name: "apply_plan", arguments: ["planId": .string("board"), "commit": .bool(false)]))
                #expect(readiness["ready"] as? Bool == (sourceDuration == 3))
                let assembly = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("board"), "commit": .bool(true)])
                if sourceDuration == 2 {
                    #expect(current["canProduce"] as? Bool == false)
                    #expect((card["blockers"] as? [String])?.contains("source_span_duration_mismatch") == true)
                    #expect(assembly.isError == true)
                    #expect(harness.editor.timeline == baseline)
                    #expect(harness.editor.editPlans == plans)
                    #expect(!undo.canUndo)
                } else {
                    #expect(current["canProduce"] as? Bool == true)
                    #expect(card["playbackSourceFrames"] as? [Int] == [30, 120])
                    #expect(assembly.isError != true)
                    let readback = try json(try await client.callTool(name: "get_timeline"))
                    #expect(readback["tracks"] != nil)
                    let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.mediaRef == "source" })
                    #expect(clip.startFrame == 0)
                    #expect(clip.trimStartFrame == 30)
                    #expect(clip.durationFrames == 90)
                    _ = try await client.callTool(name: "undo")
                    #expect(harness.editor.timeline == baseline)
                    #expect(harness.editor.editPlans == plans)
                    #expect(!undo.canUndo)
                }
            }
        } catch {
            try await PlanNarrationFixtures.remove(directory)
            throw error
        }
        try await PlanNarrationFixtures.remove(directory)
    }

    @Test(arguments: ["script", "span", "rights", "source", "cancel"])
    func materialChangesCannotReuseApproval(change: String) async throws {
        try await withClient { client, harness, _ in
            try await createPlan(client)
            let prepared = try await board(client, "prepare_storyboard")
            _ = try await inspect(client, prepared: prepared)
            _ = try await approve(client, prepared: prepared)
            if change == "cancel" {
                _ = try await board(client, "cancel_production")
            } else if change == "source" {
                harness.editor.mediaManifest.entries[0].inputIdentity = .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 3)
            } else {
                var plan = try #require(harness.editor.editPlan(id: "board"))
                switch change {
                case "script": plan.scriptBeats?[0].spokenText = "Changed pronunciation."
                case "span": plan.shots[0].endFrame = 90
                default: plan.shots[0].license = "Different license"
                }
                try harness.editor.changeEditPlans(updates: [plan], actionName: "Revise")
            }
            let current = try await board(client, "read_storyboard")
            #expect(current["canProduce"] as? Bool == false)
            #expect(current["phase"] as? String == (change == "cancel" ? "canceled" : "stale"))
            let baseline = harness.editor.editPlans
            let stale = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("approve_storyboard"), "planId": .string("board"),
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)),
            ])
            #expect(stale.isError == true)
            #expect(harness.editor.editPlans == baseline)
            let assembly = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("board"), "commit": .bool(true)])
            #expect(assembly.isError == true)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        }
    }

    @Test(arguments: ["faces", "rights", "similarity", "samples", "stale"])
    func negativeInspectionNeverCreatesApproval(reason: String) async throws {
        try await withClient { client, harness, _ in
            try await createPlan(client)
            let prepared = try await board(client, "prepare_storyboard")
            let baseline = harness.editor.editPlans
            let inspected = try await inspect(client, prepared: prepared, reason: reason)
            if reason == "samples" || reason == "stale" {
                #expect(inspected["error"] as? Bool == true)
                #expect(harness.editor.editPlans == baseline)
            } else { #expect((inspected["blockers"] as? [String])?.isEmpty == false) }
            let result = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("approve_storyboard"), "planId": .string("board"),
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)),
            ])
            #expect(result.isError == true)
            #expect(harness.editor.editPlan(id: "board")?.productionRun?.approvedRevision == nil)
        }
    }

    @Test func plainStatusCannotBypassPreparedBoard() async throws {
        try await withClient { client, harness, _ in
            try await createPlan(client)
            _ = try await board(client, "prepare_storyboard")
            let baseline = harness.editor.editPlans
            let status = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("status"), "planId": .string("board"), "status": .string("approved"),
            ])
            #expect(status.isError == true)
            #expect(harness.editor.editPlans == baseline)
        }
    }

    @Test func changedSourceBytesRefuseApprovalWithoutMutatingReview() async throws {
        try await withClient { client, harness, directory in
            try await createPlan(client)
            let prepared = try await board(client, "prepare_storyboard")
            _ = try await inspect(client, prepared: prepared)
            let baseline = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            try await Self.changeBytes(directory.appendingPathComponent("original.png"))
            let approval = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("approve_storyboard"), "planId": .string("board"),
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)),
            ])
            #expect(approval.isError == true)
            #expect(harness.editor.editPlans == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test func revisedScriptRetainsOnlyUnchangedSelectionInspection() async throws {
        try await withClient { client, harness, _ in
            try await createPlan(client)
            let prepared = try await board(client, "prepare_storyboard")
            _ = try await inspect(client, prepared: prepared)
            _ = try await approve(client, prepared: prepared)
            var plan = try #require(harness.editor.editPlan(id: "board"))
            let review = plan.productionRun?.visualReviews
            plan.scriptBeats?[0].text = "A shorter connection."
            try harness.editor.changeEditPlans(updates: [plan], actionName: "Shorten")
            let revised = try await board(client, "prepare_storyboard")
            #expect(revised["storyboardRevision"] as? String != prepared["storyboardRevision"] as? String)
            #expect(harness.editor.editPlan(id: "board")?.productionRun?.visualReviews == review)
            #expect(harness.editor.editPlan(id: "board")?.productionRun?.approvedRevision == nil)
            #expect((revised["blockers"] as? [String])?.isEmpty == true)
        }
    }

    @concurrent private static func changeBytes(_ url: URL) async throws {
        try Data("changed selected source".utf8).write(to: url)
    }

    private func createPlan(_ client: Client, duplicate: Bool = false) async throws {
        func shot(_ id: String, _ ref: String, _ start: Int) -> Value {
            .object(["shotId": .string(id), "title": .string(id), "startFrame": .int(start), "endFrame": .int(start + 60),
                "mediaRef": .string(ref), "license": .string("CC0"), "attribution": .string("Original licensed source"),
                "narrationLink": .object(["firstBeatId": .string("beat"), "lastBeatId": .string("beat"), "minimumHoldSeconds": .double(1)])])
        }
        var shots = [shot("scene", "source", 0)]
        if duplicate { shots.append(shot("other", "copy", 120)) }
        let result = try await client.callTool(name: "plan_edit", arguments: ["action": .string("create"), "plan": .object([
            "planId": .string("board"), "name": .string("Review"), "shots": .array(shots),
            "scriptBeats": .array([.object(["beatId": .string("beat"), "text": .string("Industry connects these places."), "purpose": .string("Explain the connection")])]),
        ])])
        #expect(result.isError != true)
    }

    private func board(_ client: Client, _ action: String) async throws -> [String: Any] {
        try json(try await client.callTool(name: "plan_edit", arguments: ["action": .string(action), "planId": .string("board")]))
    }

    private func inspect(_ client: Client, prepared: [String: Any], reason: String = "") async throws -> [String: Any] {
        let card = try #require((prepared["cards"] as? [[String: Any]])?.first)
        let result = try await client.callTool(name: "plan_edit", arguments: [
            "action": .string("review_storyboard_scene"), "planId": .string("board"), "sceneId": .string("scene"),
            "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)),
            "selectionRevision": .string(reason == "stale" ? String(repeating: "f", count: 64) : try #require(card["selectionRevision"] as? String)),
            "coverage": .string(reason == "samples" || card["inspectionSourceSpan"] != nil ? "full_span_playback" : "full_still_inspection"),
            "reviewer": .string("Fixture reviewer"), "evidence": .string("Inspected entire fixture still; supplied CC0 rights."),
            "facesRevealed": .bool(reason == "faces"), "rightsConfirmed": .bool(reason != "rights"), "suspectedDuplicate": .bool(reason == "similarity"),
        ])
        if result.isError == true { return ["error": true] }
        return try json(result)
    }

    private func approve(_ client: Client, prepared: [String: Any]) async throws -> [String: Any] {
        let result = try await client.callTool(name: "plan_edit", arguments: [
            "action": .string("approve_storyboard"), "planId": .string("board"),
            "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)), "comment": .string("Approved supplied script and intended pacing."),
        ])
        #expect(result.isError != true)
        return try json(result)
    }

    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        for block in result.content {
            if case .text(let value, _, _) = block {
                return try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    @concurrent private func roundTrip(_ plan: EditPlan) async throws -> EditPlan {
        try #require(EditPlanStore.decode(EditPlanStore.encode([plan])).first)
    }

    private func withClient(timingService: NarrationTimingService = .shared, type: ClipType = .image,
                            _ operation: @MainActor (Client, ToolHarness, URL) async throws -> Void) async throws {
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        let harness = ToolHarness()
        let asset = harness.addAsset(id: "source", type: type, duration: type == .image ? 0 : 5)
        asset.hasAudio = false
        asset.url = directory.appendingPathComponent("original.png")
        if type == .video {
            do {
                let video = try await StoryboardTimingFixtures.video(in: directory)
                asset.url = video.url
                asset.duration = video.duration
            } catch {
                try await MediaInputIdentityFixtures.remove(directory)
                throw error
            }
        }
        try await asset.prepareInputIdentity()
        harness.editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
        let server = Server(name: "storyboard-tests", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        let executor = ToolExecutor(editor: harness.editor, narrationTimingService: timingService)
        await MCPService.registerTools(on: server, executor: executor)
        let transport = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "storyboard-tests", version: "1")
        do {
            try await server.start(transport: transport.server)
            _ = try await client.connect(transport: transport.client)
            try await operation(client, harness, directory)
        } catch {
            await server.stop()
            await client.disconnect()
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        await server.stop()
        await client.disconnect()
        try await MediaInputIdentityFixtures.remove(directory)
    }
}
