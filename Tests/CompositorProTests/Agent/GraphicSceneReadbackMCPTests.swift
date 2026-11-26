import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Graphic scene plan readback", .serialized)
@MainActor
struct GraphicSceneReadbackMCPTests {
    private func withClient(_ executor: ToolExecutor, body: (Client) async throws -> Void) async throws {
        let server = Server(name: "graphic-readback", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let pair = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "graphic-readback-tests", version: "1")
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

    @Test func graphicSceneIsRetainedOnThePlanAndReadsBack() async throws {
        try await withSavedMediaPackageTestFixture { _, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            let executor = ToolExecutor(editor: editor)

            try await withClient(executor) { (client: Client) async throws in
                let created = try await client.callTool(name: "plan_edit", arguments: [
                    "action": .string("create"),
                    "plan": .object([
                        "planId": .string("plan-graphic"),
                        "name": .string("Graphic plan"),
                        "shots": .array([
                            .object([
                                "shotId": .string("shot-1"),
                                "title": .string("Assembly share"),
                                "startFrame": .int(0),
                                "endFrame": .int(60),
                            ]),
                        ]),
                    ]),
                ])
                #expect(created.isError != true)

                let graphic = try await client.callTool(name: "build_graphic_scene", arguments: [
                    "kind": .string("numeric_comparison"),
                    "title": .string("Assembly share"),
                    "items": .array([
                        .object(["label": .string("A"), "value": .double(13), "unit": .string("percent")]),
                        .object(["label": .string("B"), "value": .double(4.5), "unit": .string("percent")]),
                    ]),
                    "durationFrames": .int(30),
                    "width": .int(480),
                    "height": .int(270),
                    "addToTimeline": .bool(true),
                    "startFrame": .int(0),
                    "planId": .string("plan-graphic"),
                ])
                #expect(graphic.isError != true)

                let read = try await client.callTool(name: "plan_edit", arguments: [
                    "action": .string("read"),
                    "planId": .string("plan-graphic"),
                ])
                #expect(read.isError != true)
                let content = try #require(read.content.first)
                guard case .text(let json, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
                let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                let scenes = try #require(object["graphicScenes"] as? [[String: Any]])
                #expect(scenes.count == 1)
                #expect(scenes.first?["kind"] as? String == "numeric_comparison")
                #expect((scenes.first?["digest"] as? String)?.isEmpty == false)
                #expect((scenes.first?["mediaRef"] as? String)?.isEmpty == false)
                #expect((scenes.first?["rendererVersion"] as? String)?.isEmpty == false)
            }
        }
    }
}
