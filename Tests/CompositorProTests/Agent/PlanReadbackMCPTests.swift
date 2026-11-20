import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Plan readback through MCP", .serialized)
@MainActor
struct PlanReadbackMCPTests {
    private func harnessWithPlan() throws -> (ToolHarness, String) {
        let harness = ToolHarness()
        var plan = EditPlan(name: "Plan", timelineId: harness.editor.timeline.id, fps: 30, width: 1920, height: 1080)
        plan.sections = [EditPlanSection(id: "sec-1", title: "Intro", summary: "Hook", startFrame: 0, endFrame: 90)]
        plan.scriptBeats = [
            ScriptBeat(beatId: "b1", text: "First", purpose: "hook"),
            ScriptBeat(beatId: "b2", text: "Second", purpose: "context"),
        ]
        plan.narrationRevision = UUID().uuidString
        plan.sections[0].narrationLink = SceneNarrationLink(firstBeatId: "b1", lastBeatId: "b1")
        plan = try EditPlan.validatedNew(plan, timelineId: plan.timelineId, fps: 30, width: 1920, height: 1080, existingCount: 0)
        harness.editor.editPlans = [plan]
        let stored = try #require(harness.editor.editPlans.first)
        return (harness, stored.id)
    }

    private func withClient(_ harness: ToolHarness, body: (Client) async throws -> Void) async throws {
        let server = Server(name: "plan-readback", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let pair = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "plan-readback-tests", version: "1")
        try await server.start(transport: pair.server)
        do {
            _ = try await client.connect(transport: pair.client)
            try await body(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func reviseSectionIsVisibleOnTheNextMCPRead() async throws {
        let (harness, planId) = try harnessWithPlan()
        let before = try #require(harness.editor.editPlan(id: planId))
        #expect(before.narrationTiming == nil)

        try await withClient(harness) { (client: Client) async throws in
            let revised = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("revise_section"),
                "planId": .string(planId),
                "sectionId": .string("sec-1"),
                "title": .string("Intro v2"),
                "summary": .string("Rewritten hook"),
                "beatText": .object(["b1": .string("Rewritten")]),
            ])
            #expect(revised.isError != true)

            let read = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("read"),
                "planId": .string(planId),
            ])
            #expect(read.isError != true)
            let text = try #require(read.content.first)
            guard case .text(let json, _, _) = text else { throw CocoaError(.coderReadCorrupt) }
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let sections = try #require(object["sections"] as? [[String: Any]])
            #expect((object["planId"] as? String)?.isEmpty == false)
            #expect(sections.first?["title"] as? String == "Intro v2")
            #expect(json.contains("Rewritten"))
        }

        let storedPlan = try #require(harness.editor.editPlan(id: planId))
        #expect(storedPlan.sections.first?.title == "Intro v2")
        #expect(storedPlan.scriptBeats?.first { $0.beatId == "b1" }?.text == "Rewritten")
        // A material section change invalidates derived narration timing for re-measurement.
        #expect(storedPlan.narrationTiming == nil)
    }
}
