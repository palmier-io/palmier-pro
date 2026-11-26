import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Prepared plan assembly through MCP")
@MainActor
struct PlanAssemblyMCPTests {
    @Test func preparesCommitsReadsPersistsRetriesAndUndoesExactly() async throws {
        try await withEditor { editor, directory in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            let before = editor.timeline
            let manager = UndoManager()
            editor.undo.attach(manager)
            try await withClient(editor: editor) { client in
                let (tools, _) = try await client.listTools()
                let apply = try #require(tools.first { $0.name == "apply_plan" })
                #expect(apply.inputSchema.objectValue?["properties"]?.objectValue?["preparationId"] != nil)
                #expect(apply.inputSchema.objectValue?["properties"]?.objectValue?["shotIds"] != nil)
                let ready = try await call(client, "apply_plan", ["planId": .string(plan.id)])
                let preparation = try #require(ready["preparationId"] as? String)
                let planned = try #require(ready["shotAssembly"] as? [[String: Any]])
                #expect(ready["ready"] as? Bool == true && ready["noOp"] as? Bool == true)
                #expect(editor.timeline == before && !manager.canUndo)
                let applied = try await call(client, "apply_plan", ["planId": .string(plan.id),
                    "preparationId": .string(preparation), "commit": .bool(true)])
                #expect(applied["changed"] as? Bool == true && applied["applied"] as? Bool == true)
                let appliedShots = try #require(applied["shotAssembly"] as? [[String: Any]])
                for (proposed, committed) in zip(planned, appliedShots) {
                    let fullIds = try #require(proposed["clipIds"] as? [String])
                    let returnedIds = try #require(committed["clipIds"] as? [String])
                    #expect(fullIds.count == returnedIds.count)
                    #expect(zip(fullIds, returnedIds).allSatisfy { $0.hasPrefix($1) })
                }
                let assembled = editor.timeline
                let storedPlan = try #require(editor.editPlan(id: plan.id))
                let state = try #require(storedPlan.assembly)
                #expect(state.bindings.count == 2 && assembled.tracks.flatMap(\.clips).count == 4)
                let opening = try #require(state.bindings.first { $0.intent.elementId == "opening" })
                #expect(opening.intent.sourceAudio == .linked && opening.clips.count == 2)
                #expect(opening.clips.allSatisfy { $0.clip.trimStartFrame == 30 && $0.clip.trimEndFrame == 90 })
                let read = try await call(client, "get_timeline")
                #expect(read["totalFrames"] as? Int == 60)
                let readPlan = try await call(client, "plan_edit", ["action": .string("read"), "planId": .string(plan.id)])
                #expect((readPlan["assembly"] as? [String: Any])?["revision"] as? String == state.revision)
                let persisted = try await PlanAssemblyFixtures.persisted(plan: storedPlan, timeline: assembled, directory: directory)
                #expect(persisted.0 == storedPlan && persisted.1 == assembled)
                let retry = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                #expect(retry["noOp"] as? Bool == true && retry["changed"] as? Bool == false)
                #expect(editor.timeline == assembled && editor.editPlan(id: plan.id) == storedPlan)
                #expect(try await client.callTool(name: "undo", arguments: [:]).isError != true)
                #expect(editor.timeline == before && editor.editPlan(id: plan.id) == plan && !manager.canUndo)
                manager.redo()
                #expect(editor.timeline == assembled && editor.editPlan(id: plan.id) == storedPlan)
            }
        }
    }

    @Test(arguments: ["settings", "track order", "source bytes", "plan", "timeline", "project"])
    func stalePreparationCannotCommit(change: String) async throws {
        try await withEditor { editor, directory in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            try await withClient(editor: editor) { client in
                let ready = try await call(client, "apply_plan", ["planId": .string(plan.id)])
                let preparation = try #require(ready["preparationId"] as? String)
                switch change {
                case "settings": editor.timeline.width = 1080
                case "track order": editor.timeline.tracks.insert(Track(type: .video), at: 0)
                case "source bytes":
                    try await overwriteSource(directory.appendingPathComponent("assembly.mov"))
                case "plan":
                    var revised = plan
                    revised.notes = "Changed while preparing"
                    try editor.changeEditPlans(updates: [revised], actionName: "Notes")
                case "timeline": editor.createTimeline(name: "Other")
                default: editor.projectURL = directory.appendingPathComponent("Other.compositorpro")
                }
                let before = editor.timeline
                let plans = editor.editPlans
                let manager = UndoManager()
                editor.undo.attach(manager)
                let result = try await client.callTool(name: "apply_plan", arguments: ["planId": .string(plan.id),
                    "preparationId": .string(preparation), "commit": .bool(true)])
                #expect(result.isError == true)
                #expect(editor.timeline == before && editor.editPlans == plans && !manager.canUndo)
            }
        }
    }

    @Test func subsetRevisionPreservesUntargetedManualLookAndStableIds() async throws {
        try await withEditor { editor, _ in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                let old = try #require(editor.editPlan(id: plan.id)?.assembly)
                let ending = try #require(old.bindings.first { $0.intent.elementId == "ending" })
                let location = try #require(editor.findClip(id: ending.clips[0].clip.id))
                editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].opacity = 0.7
                let preserved = editor.timeline.tracks[location.trackIndex].clips[location.clipIndex]
                var revised = try #require(editor.editPlan(id: plan.id))
                revised.shots[0].sourceStartSeconds = 2
                revised.shots[0].sourceEndSeconds = 3
                try editor.changeEditPlans(updates: [revised], actionName: "Revise Opening")
                #expect(editor.editPlan(id: plan.id)?.status == .proposed)
                try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve Revision")
                let before = editor.timeline
                let manager = UndoManager()
                editor.undo.attach(manager)
                let receipt = try await call(client, "apply_plan", ["planId": .string(plan.id),
                    "shotIds": .array([.string("opening")]), "commit": .bool(true)])
                #expect(receipt["applied"] as? Bool == true)
                let state = try #require(editor.editPlan(id: plan.id)?.assembly)
                #expect(state.bindings.first { $0.intent.elementId == "ending" } == ending)
                let newOpening = try #require(state.bindings.first { $0.intent.elementId == "opening" })
                #expect(newOpening.clips.map { $0.clip.id } == old.bindings.first { $0.intent.elementId == "opening" }?.clips.map { $0.clip.id })
                #expect(newOpening.clips.allSatisfy { $0.clip.trimStartFrame == 60 })
                #expect(editor.timeline.tracks.flatMap(\.clips).first { $0.id == preserved.id } == preserved)
                manager.undo()
                #expect(editor.timeline == before)
            }
        }
    }

    @Test func manuallyChangedTargetRequiresExplicitReplacement() async throws {
        try await withEditor { editor, _ in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                let binding = try #require(editor.editPlan(id: plan.id)?.assembly?.bindings.first { $0.intent.elementId == "opening" })
                let location = try #require(editor.findClip(id: binding.clips[0].clip.id))
                editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].startFrame = 1
                let before = editor.timeline
                let manager = UndoManager()
                editor.undo.attach(manager)
                let args: [String: Value] = ["planId": .string(plan.id), "shotIds": .array([.string("opening")]), "commit": .bool(true)]
                #expect(try await client.callTool(name: "apply_plan", arguments: args).isError == true)
                #expect(editor.timeline == before && !manager.canUndo)
                var authorized = args
                authorized["replaceManualEdits"] = .bool(true)
                let result = try await call(client, "apply_plan", authorized)
                #expect(result["changed"] as? Bool == true)
                #expect(editor.timeline.tracks.flatMap(\.clips).first { $0.id == binding.clips[0].clip.id }?.startFrame == 0)
                manager.undo()
                #expect(editor.timeline == before && !manager.canUndo)
            }
        }
    }

    @Test func occupiedExplicitTrackRefusesWithoutTouchingUnrelatedEdits() async throws {
        try await withEditor { editor, _ in
            editor.timeline.tracks = [Fixtures.videoTrack(id: "occupied", clips: [Fixtures.clip(id: "manual", start: 0, duration: 90)])]
            var plan = try PlanAssemblyFixtures.plan(in: editor)
            plan.shots[0].trackId = "occupied"
            try editor.changeEditPlans(updates: [plan], actionName: "Choose Track")
            try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve")
            let before = editor.timeline
            let manager = UndoManager()
            editor.undo.attach(manager)
            try await withClient(editor: editor) { client in
                let ready = try await call(client, "apply_plan", ["planId": .string(plan.id)])
                #expect(ready["ready"] as? Bool == false)
                #expect((ready["blockers"] as? [String])?.contains { $0.contains("overlaps") } == true)
                #expect(try await client.callTool(name: "apply_plan", arguments: ["planId": .string(plan.id), "commit": .bool(true)]).isError == true)
                #expect(editor.timeline == before && !manager.canUndo)
            }
        }
    }

    @Test func nestedTimelineProducesLinkedCarriersWithoutMutatingChild() async throws {
        try await withEditor { editor, _ in
            let child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "assembly-source", start: 0, duration: 90)]),
                Fixtures.audioTrack(clips: [Fixtures.clip(mediaRef: "assembly-source", mediaType: .audio, start: 0, duration: 90)])])
            editor.timelines.append(child)
            let plan = try PlanAssemblyFixtures.plan(in: editor, sourceId: child.id)
            var revised = plan
            revised.shots[1].sourceStartSeconds = 1
            revised.shots[1].sourceEndSeconds = 2
            try editor.changeEditPlans(updates: [revised], actionName: "Source Range")
            try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve")
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                let clips = editor.timeline.tracks.flatMap(\.clips)
                #expect(clips.count == 4 && clips.allSatisfy { $0.sourceClipType == .sequence && $0.mediaRef == child.id })
                #expect(editor.timeline(for: child.id) == child)
                #expect(try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])["noOp"] as? Bool == true)
            }
        }
    }

    @Test func reorderedTracksResolveByStableId() async throws {
        try await withEditor { editor, _ in
            editor.timeline.tracks = [Fixtures.videoTrack(id: "one"), Fixtures.videoTrack(id: "two"), Fixtures.audioTrack(id: "audio")]
            var plan = try PlanAssemblyFixtures.plan(in: editor)
            for index in plan.shots.indices { plan.shots[index].trackId = "one"; plan.shots[index].sourceAudio = .omit }
            try editor.changeEditPlans(updates: [plan], actionName: "Choose Track")
            try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve")
            editor.timeline.tracks.swapAt(0, 1)
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                #expect(editor.timeline.tracks[0].id == "two" && editor.timeline.tracks[0].clips.isEmpty)
                #expect(editor.timeline.tracks[1].id == "one" && editor.timeline.tracks[1].clips.count == 2)
                #expect(editor.timeline.tracks.last?.clips.isEmpty == true)
            }
        }
    }

    @Test(arguments: ["before preparation", "after preparation", "retry"])
    func missingSourceNeverUsesCachedIdentity(phase: String) async throws {
        try await withEditor { editor, directory in
            let source = try #require(editor.mediaAssets.first)
            source.inputIdentity = try await MediaInputIdentityService.shared.identify(source.url, force: true)
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            try await withClient(editor: editor) { client in
                var args: [String: Value] = ["planId": .string(plan.id), "commit": .bool(true)]
                if phase == "retry" { _ = try await call(client, "apply_plan", args) }
                if phase == "after preparation" {
                    let ready = try await call(client, "apply_plan", ["planId": .string(plan.id)])
                    args["preparationId"] = .string(try #require(ready["preparationId"] as? String))
                }
                try await removeSource(directory.appendingPathComponent("assembly.mov"))
                let before = editor.timeline
                let plans = editor.editPlans
                let manager = UndoManager()
                editor.undo.attach(manager)
                let result = try await client.callTool(name: "apply_plan", arguments: args)
                #expect(result.isError == true)
                #expect(editor.timeline == before && editor.editPlans == plans && !manager.canUndo)
            }
        }
    }

    @Test(arguments: [false, true])
    func replacementCannotBreakUnrelatedLink(changedGroup: Bool) async throws {
        try await withEditor { editor, _ in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                let binding = try #require(editor.editPlan(id: plan.id)?.assembly?.bindings.first { $0.intent.elementId == "opening" })
                let location = try #require(editor.findClip(id: binding.clips[0].clip.id))
                let group = changedGroup ? UUID().uuidString : try #require(binding.clips[0].clip.linkGroupId)
                editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].linkGroupId = group
                editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].startFrame = 1
                var unrelated = Fixtures.clip(id: "unrelated", start: 90, duration: 30)
                unrelated.linkGroupId = group
                editor.timeline.tracks[location.trackIndex].clips.append(unrelated)
                let before = editor.timeline
                let manager = UndoManager()
                editor.undo.attach(manager)
                let result = try await client.callTool(name: "apply_plan", arguments: ["planId": .string(plan.id),
                    "shotIds": .array([.string("opening")]), "replaceManualEdits": .bool(true), "commit": .bool(true)])
                #expect(result.isError == true)
                #expect(editor.timeline == before && !manager.canUndo)
            }
        }
    }

    @Test func uuidShotSubsetAcceptsReturnedIdPrefix() async throws {
        try await withEditor { editor, _ in
            var plan = try PlanAssemblyFixtures.plan(in: editor)
            let shotId = UUID().uuidString
            plan.shots[0].id = shotId
            try editor.changeEditPlans(updates: [plan], actionName: "Shot ID")
            try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve")
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                let result = try await call(client, "apply_plan", ["planId": .string(plan.id),
                    "shotIds": .array([.string(String(shotId.prefix(8)))]), "commit": .bool(true)])
                #expect(result["noOp"] as? Bool == true)
            }
        }
    }

    @Test(arguments: ["cancel", "timeline", "plan", "availability", "project", "close"])
    func interruptedPreparationCannotCommit(change: String) async throws {
        try await withEditor { editor, directory in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            let entered = AsyncSemaphore(value: 0)
            let resume = AsyncSemaphore(value: 0)
            let finished = AsyncSemaphore(value: 0)
            let manager = UndoManager()
            editor.undo.attach(manager)
            try await withClient(editor: editor, prepare: { input in
                await entered.signal()
                do {
                    try await resume.wait()
                    let result = try await PlanAssembly.prepare(input)
                    await finished.signal()
                    return result
                } catch {
                    await finished.signal()
                    throw error
                }
            }) { client in
                let request: RequestContext<CallTool.Result> = try await client.callTool(name: "apply_plan", arguments: [
                    "planId": .string(plan.id), "commit": .bool(true),
                ])
                try await entered.wait()
                switch change {
                case "cancel": try await client.cancelRequest(request.requestID, reason: "Fixture cancellation")
                case "timeline": editor.timeline.width += 1
                case "plan": editor.editPlans[0].notes = "Concurrent edit"
                case "availability": editor.mediaAssets[0].generationStatus = .downloading
                case "project": editor.projectURL = directory.appendingPathComponent("SaveAs.compositorpro")
                default: _ = editor.projectPackageCoordinator.beginClosing()
                }
                let timelines = editor.timelines
                let plans = editor.editPlans
                await resume.signal()
                if change == "cancel" {
                    await #expect(throws: CancellationError.self) { try await request.value }
                } else { #expect(try await request.value.isError == true) }
                try await finished.wait()
                #expect(editor.timelines == timelines && editor.editPlans == plans && !manager.canUndo)
                #expect(editor.preparedPlanAssembly == nil)
            }
        }
    }

    @Test(arguments: ["transition", "multicam", "removed"])
    func protectedOwnedShotRequiresSafeExplicitReplacement(protection: String) async throws {
        try await withEditor { editor, _ in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                let assembly = try #require(editor.editPlan(id: plan.id)?.assembly)
                let opening = try #require(assembly.bindings.first { $0.intent.elementId == "opening" })
                let ending = try #require(assembly.bindings.first { $0.intent.elementId == "ending" })
                let location = try #require(editor.findClip(id: opening.clips[0].clip.id))
                if protection == "transition" {
                    editor.timeline.transitions.append(.init(outgoingClipId: opening.clips[0].clip.id,
                        incomingClipId: ending.clips[0].clip.id, trackId: opening.clips[0].trackId, type: .dissolve, durationFrames: 6))
                } else if protection == "multicam" {
                    editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].multicamGroupId = "group"
                } else { editor.timeline.tracks[location.trackIndex].clips.remove(at: location.clipIndex) }
                var revised = try #require(editor.editPlan(id: plan.id))
                revised.shots[0].sourceStartSeconds = 2
                revised.shots[0].sourceEndSeconds = 3
                try editor.changeEditPlans(updates: [revised], actionName: "Revise")
                try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve")
                let before = editor.timeline
                let manager = UndoManager()
                editor.undo.attach(manager)
                var args: [String: Value] = ["planId": .string(plan.id), "shotIds": .array([.string("opening")]), "commit": .bool(true)]
                #expect(try await client.callTool(name: "apply_plan", arguments: args).isError == true)
                #expect(editor.timeline == before && !manager.canUndo)
                args["replaceManualEdits"] = .bool(true)
                if protection == "removed" {
                    #expect(try await call(client, "apply_plan", args)["applied"] as? Bool == true)
                    #expect(editor.clipFor(id: opening.clips[0].clip.id)?.trimStartFrame == 60)
                    manager.undo()
                    #expect(editor.timeline == before)
                } else {
                    #expect(try await client.callTool(name: "apply_plan", arguments: args).isError == true)
                    #expect(editor.timeline == before && !manager.canUndo)
                }
            }
        }
    }

    @Test func incompleteSubsetDoesNotClaimFullAssembly() async throws {
        try await withEditor { editor, _ in
            let plan = try PlanAssemblyFixtures.plan(in: editor)
            try await withClient(editor: editor) { client in
                _ = try await call(client, "apply_plan", ["planId": .string(plan.id), "commit": .bool(true)])
                var revised = try #require(editor.editPlan(id: plan.id))
                for index in revised.shots.indices {
                    revised.shots[index].sourceStartSeconds = 0
                    revised.shots[index].sourceEndSeconds = 1
                }
                try editor.changeEditPlans(updates: [revised], actionName: "Revise")
                try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve")
                let result = try await call(client, "apply_plan", ["planId": .string(plan.id),
                    "shotIds": .array([.string("opening")]), "commit": .bool(true)])
                #expect(result["applied"] as? Bool == false)
                #expect(editor.editPlan(id: plan.id)?.status == .approved)
                #expect((result["warnings"] as? [String])?.contains { $0.contains("does not complete") } == true)
            }
        }
    }

    private func withEditor(_ body: (EditorViewModel, URL) async throws -> Void) async throws {
        let directory = try await PlanAssemblyFixtures.makeDirectory()
        do {
            let editor = EditorViewModel()
            PlanAssemblyFixtures.addSource(to: editor, directory: directory)
            try await body(editor, directory)
        } catch {
            try await AudioFinishingFixtures.remove(directory)
            throw error
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    private func withClient(
        editor: EditorViewModel,
        prepare: @escaping EditorViewModel.PlanAssemblyPreparing = { try await PlanAssembly.prepare($0) },
        _ body: (Client) async throws -> Void
    ) async throws {
        let executor = ToolExecutor(editor: editor, planAssemblyPreparing: prepare)
        let server = Server(name: "plan-assembly", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "plan-assembly-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await body(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func call(_ client: Client, _ name: String, _ args: [String: Value] = [:]) async throws -> [String: Any] {
        let result = try await client.callTool(name: name, arguments: args)
        try #require(result.isError != true)
        for item in result.content {
            if case .text(let text, _, _) = item {
                return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    @concurrent
    private func overwriteSource(_ url: URL) async throws { try Data("changed".utf8).write(to: url) }

    @concurrent
    private func removeSource(_ url: URL) async throws { try FileManager.default.removeItem(at: url) }
}
