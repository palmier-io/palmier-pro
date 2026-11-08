import CoreGraphics
import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Storyboard editing")
@MainActor
struct StoryboardEditingTests {
    @Test func reorderMovesNarrationAndSectionsPreservesIDsAndUndoesThroughMCP() async throws {
        try await withClient { client, harness in
            let prepared = try await call(client, action: "prepare_storyboard")
            let revision = try #require(prepared["storyboardRevision"] as? String)
            let baseline = try #require(harness.editor.editPlan(id: "plan"))
            let timeline = harness.editor.timeline
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let changed = try await call(client, action: "reorder_storyboard", fields: [
                "storyboardRevision": .string(revision), "sceneIds": .array([.string("second"), .string("first")]),
            ])
            #expect(changed["phase"] as? String == "stale")
            let plan = try #require(harness.editor.editPlan(id: "plan"))
            #expect(plan.shots.map(\.id) == ["second", "first"])
            #expect(plan.shots.map(\.startFrame) == [0, 90])
            #expect(plan.shots.map(\.endFrame) == [90, 150])
            #expect(plan.scriptBeats?.map(\.beatId) == ["b", "a"])
            #expect(plan.sections.map(\.id) == ["chapter-b", "chapter-a"])
            #expect(plan.sections.map(\.startFrame) == [0, 90])
            #expect(plan.shots.map(\.mediaRef) == ["visual-b", "visual-a"])
            let repeated = try await call(client, action: "reorder_storyboard", fields: [
                "storyboardRevision": .string(try #require(changed["storyboardRevision"] as? String)),
                "sceneIds": .array([.string("second"), .string("first")]),
            ])
            #expect(repeated["noOp"] as? Bool == true)
            #expect(try await client.callTool(name: "undo").isError != true)
            #expect(harness.editor.editPlan(id: "plan") == baseline)
            #expect(harness.editor.timeline == timeline)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(harness.editor.editPlan(id: "plan") == plan)
            let readback = try await call(client, action: "read_storyboard")
            #expect((readback["cards"] as? [[String: Any]])?.compactMap { $0["sceneId"] as? String } == ["second", "first"])
            let persisted = try await Self.roundTrip(plan)
            #expect(persisted.shots == plan.shots)
            #expect(persisted.sections == plan.sections)
            #expect(persisted.scriptBeats == plan.scriptBeats)
            #expect(persisted.narrationRevision == plan.narrationRevision)
            #expect(persisted.productionRun == plan.productionRun)
        }
    }

    @Test func oneSceneRevisionUpdatesNarrationAndVisualAtomicallyAndRevokesApproval() async throws {
        try await withClient { client, harness in
            let prepared = try await call(client, action: "prepare_storyboard")
            let revision = try #require(prepared["storyboardRevision"] as? String)
            try await inspectAndApprove(client, prepared: prepared)
            let baseline = try #require(harness.editor.editPlan(id: "plan"))
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let result = try await call(client, action: "revise_storyboard_scene", fields: [
                "storyboardRevision": .string(revision), "sceneId": .string("first"),
                "beatEdits": .array([.object(["beatId": .string("a"), "text": .string("Revised claim."), "spokenText": .string("Revised pronunciation.")])]),
                "visual": .object(["mediaRef": .string("visual-c"), "license": .string("CC0"), "attribution": .string("Third fixture")]),
            ])
            #expect(result["phase"] as? String == "stale")
            let plan = try #require(harness.editor.editPlan(id: "plan"))
            #expect(plan.scriptBeats?.first?.text == "Revised claim.")
            #expect(plan.scriptBeats?.first?.spokenText == "Revised pronunciation.")
            #expect(plan.scriptBeats?.first?.purpose == baseline.scriptBeats?.first?.purpose)
            #expect(plan.shots.first?.mediaRef == "visual-c")
            #expect(plan.productionRun?.approvedRevision == nil)
            #expect(plan.narrationRevision != baseline.narrationRevision)
            #expect(plan.shots[1] == baseline.shots[1])
            let current = try await call(client, action: "read_storyboard")
            #expect(current["storyboardRevision"] as? String == result["storyboardRevision"] as? String)
            #expect(current["canProduce"] as? Bool == false)
            let repeated = try await call(client, action: "revise_storyboard_scene", fields: [
                "storyboardRevision": .string(try #require(current["storyboardRevision"] as? String)), "sceneId": .string("first"),
                "beatEdits": .array([.object(["beatId": .string("a"), "text": .string("Revised claim."), "spokenText": .string("Revised pronunciation.")])]),
            ])
            #expect(repeated["noOp"] as? Bool == true)
            #expect(try await client.callTool(name: "undo").isError != true)
            #expect(harness.editor.editPlan(id: "plan") == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: ["duplicate", "foreign-beat", "unknown-visual", "audio", "stale", "unknown-key", "empty", "duplicate-beat", "invalid-span"])
    func invalidRevisionLeavesPlanAndUndoUnchanged(reason: String) async throws {
        try await withClient { client, harness in
            let prepared = try await call(client, action: "prepare_storyboard")
            let baseline = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            var fields: [String: Value] = ["action": .string("revise_storyboard_scene"), "planId": .string("plan"),
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)), "sceneId": .string("first")]
            switch reason {
            case "duplicate", "unknown-visual", "audio":
                if reason == "audio" { _ = harness.addAsset(id: "audio", type: .audio) }
                fields["visual"] = .object(["mediaRef": .string(reason == "duplicate" ? "visual-b" : reason == "audio" ? "audio" : "absent"),
                    "license": .string("CC0"), "attribution": .string("Fixture")])
            case "invalid-span": fields["visual"] = .object(["mediaRef": .string("visual-c"), "license": .string("CC0"),
                "attribution": .string("Fixture"), "sourceStartSeconds": .double(2), "sourceEndSeconds": .double(1)])
            case "stale":
                fields["storyboardRevision"] = .string(String(repeating: "f", count: 64))
                fields["beatEdits"] = .array([.object(["beatId": .string("a"), "text": .string("New.")])])
            case "foreign-beat": fields["beatEdits"] = .array([.object(["beatId": .string("b"), "text": .string("Wrong scene.")])])
            case "unknown-key": fields["visual"] = .object(["mediaRef": .string("visual-c"), "license": .string("CC0"),
                "attribution": .string("Fixture"), "bypass": .bool(true)])
            case "duplicate-beat": fields["beatEdits"] = .array(Array(repeating: .object(["beatId": .string("a"), "text": .string("New.")]), count: 2))
            default: break
            }
            let result = try await client.callTool(name: "plan_edit", arguments: fields)
            #expect(result.isError == true)
            #expect(harness.editor.editPlans == baseline)
            #expect(!undo.canUndo)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        }
    }

    @Test func sharedBeatEditsRefreshAllDependentCardsAndClearPronunciation() async throws {
        try await withClient { client, harness in
            var plan = try #require(harness.editor.editPlan(id: "plan"))
            plan.shots[1].narrationLink = .init(firstBeatId: "a", lastBeatId: "b")
            plan.scriptBeats?[0].spokenText = "Original pronunciation."
            try harness.editor.changeEditPlans(updates: [plan], actionName: "Share beat")
            let prepared = try await call(client, action: "prepare_storyboard")
            let baseline = try #require(harness.editor.editPlan(id: "plan"))
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            _ = try await call(client, action: "revise_storyboard_scene", fields: [
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)), "sceneId": .string("first"),
                "beatEdits": .array([.object(["beatId": .string("a"), "text": .string("Updated shared narration.")])]),
            ])
            let readback = try await call(client, action: "read_storyboard")
            let cards = try #require(readback["cards"] as? [[String: Any]])
            #expect(cards.count == 2)
            #expect(cards.allSatisfy { ($0["narration"] as? String)?.contains("Updated shared narration.") == true })
            #expect(harness.editor.editPlan(id: "plan")?.scriptBeats?.first?.spokenText == nil)
            #expect(harness.editor.editPlan(id: "plan")?.shots == baseline.shots)
            #expect(try await client.callTool(name: "undo").isError != true)
            #expect(harness.editor.editPlan(id: "plan") == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: ["applied", "canceled"])
    func inactiveBoardsRefuseRevisionWithoutMutation(state: String) async throws {
        try await withClient { client, harness in
            let prepared = try await call(client, action: "prepare_storyboard")
            if state == "applied" {
                try await inspectAndApprove(client, prepared: prepared)
                _ = try harness.editor.changeEditPlanStatus(id: "plan", to: .ready, actionName: "Ready", permitReserved: true)
                _ = try harness.editor.changeEditPlanStatus(id: "plan", to: .applied, actionName: "Apply", permitReserved: true)
            } else { _ = try await call(client, action: "cancel_production") }
            let baseline = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let result = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("revise_storyboard_scene"), "planId": .string("plan"),
                "storyboardRevision": .string(try #require(prepared["storyboardRevision"] as? String)), "sceneId": .string("first"),
                "beatEdits": .array([.object(["beatId": .string("a"), "text": .string("New narration.")])]),
            ])
            #expect(result.isError == true)
            #expect(harness.editor.editPlans == baseline)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: ["duplicate", "missing", "shared-beat", "gap", "split-section"])
    func ambiguousOrdersAreRefusedBeforeMutation(reason: String) throws {
        var plan = Self.plan(timelineId: "timeline")
        var ids = ["second", "first"]
        switch reason {
        case "duplicate": ids = ["first", "first"]
        case "missing": ids = ["first"]
        case "shared-beat": plan.shots[1].narrationLink = plan.shots[0].narrationLink
        case "gap": plan.shots[1].startFrame += 1
        default: plan.sections[0].endFrame = 30
        }
        #expect(throws: EditPlanValidationError.self) { try StoryboardEditing.reorder(plan: plan, sceneIds: ids) }
    }

    private static func plan(timelineId: String) -> EditPlan {
        EditPlan(id: "plan", name: "Two scenes", timelineId: timelineId, fps: 30, width: 1920, height: 1080,
            sections: [
                .init(id: "chapter-a", title: "First", startFrame: 0, endFrame: 60, narrationLink: .init(firstBeatId: "a", lastBeatId: "a")),
                .init(id: "chapter-b", title: "Second", startFrame: 60, endFrame: 150, narrationLink: .init(firstBeatId: "b", lastBeatId: "b")),
            ], shots: [
                .init(id: "first", title: "First", startFrame: 0, endFrame: 60, mediaRef: "visual-a", license: "CC0", attribution: "First fixture", narrationLink: .init(firstBeatId: "a", lastBeatId: "a")),
                .init(id: "second", title: "Second", startFrame: 60, endFrame: 150, mediaRef: "visual-b", license: "CC0", attribution: "Second fixture", narrationLink: .init(firstBeatId: "b", lastBeatId: "b")),
            ], scriptBeats: [
                .init(beatId: "a", text: "First claim.", purpose: "Introduce"), .init(beatId: "b", text: "Second claim.", purpose: "Explain"),
            ])
    }

    private func call(_ client: Client, action: String, fields: [String: Value] = [:]) async throws -> [String: Any] {
        let result = try await client.callTool(name: "plan_edit", arguments: fields.merging([
            "action": .string(action), "planId": .string("plan"),
        ], uniquingKeysWith: { _, new in new }))
        #expect(result.isError != true)
        for block in result.content {
            if case .text(let text, _, _) = block { return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func inspectAndApprove(_ client: Client, prepared: [String: Any]) async throws {
        let revision = try #require(prepared["storyboardRevision"] as? String)
        let cards = try #require(prepared["cards"] as? [[String: Any]])
        for card in cards {
            _ = try await call(client, action: "review_storyboard_scene", fields: [
                "storyboardRevision": .string(revision), "sceneId": .string(try #require(card["sceneId"] as? String)),
                "selectionRevision": .string(try #require(card["selectionRevision"] as? String)),
                "coverage": .string("full_still_inspection"), "reviewer": .string("Fixture reviewer"),
                "evidence": .string("Entire solid-color fixture inspected; fixture author grants CC0."),
                "facesRevealed": .bool(false), "rightsConfirmed": .bool(true), "suspectedDuplicate": .bool(false),
            ])
        }
        _ = try await call(client, action: "approve_storyboard", fields: ["storyboardRevision": .string(revision)])
    }

    private func withClient(_ operation: @MainActor (Client, ToolHarness) async throws -> Void) async throws {
        let directory = try await Self.makeImages()
        let harness = ToolHarness(timeline: Fixtures.timeline(fps: 30))
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "storyboard-edit-tests", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        let client = Client(name: "storyboard-edit-tests", version: "1")
        do {
            for name in ["a", "b", "c"] {
                let asset = harness.addAsset(id: "visual-" + name, type: .image)
                asset.url = directory.appendingPathComponent(name + ".png")
                try await asset.prepareInputIdentity()
                harness.editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
            }
            try harness.editor.changeEditPlans(creates: [Self.plan(timelineId: harness.editor.activeTimelineId)], actionName: "Create")
            await MCPService.registerTools(on: server, executor: harness.executor)
            try await server.start(transport: transports.server)
            _ = try await client.connect(transport: transports.client)
            try await operation(client, harness)
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

    @concurrent private static func roundTrip(_ plan: EditPlan) async throws -> EditPlan {
        try #require(EditPlanStore.decode(EditPlanStore.encode([plan])).first)
    }

    @concurrent private static func makeImages() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("storyboard-edits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for (index, name) in ["a", "b", "c"].enumerated() {
                let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(srgbRed: Double(index) / 2, green: 0.3, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
                let image = try #require(context.makeImage())
                let data = try #require(ImageEncoder.encodePNG(image))
                try data.write(to: directory.appendingPathComponent(name + ".png"))
            }
            return directory
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
