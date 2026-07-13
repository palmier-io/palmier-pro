import AppKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("manage_project tool", .serialized)
@MainActor
struct ManageProjectToolTests {
    @Test func replacesIndividualProjectTools() throws {
        let names = Set(ToolDefinitions.mcpServer.map { $0.name.rawValue })

        #expect(names.contains("manage_project"))
        #expect(!names.contains("get_projects"))
        #expect(!names.contains("open_project"))
        #expect(!names.contains("new_project"))
        #expect(!names.contains("close_project"))

        let tool = try #require(ToolDefinitions.mcpServer.first { $0.name == .manageProject })
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        let action = try #require(properties["action"])
        let actions = try #require(action["enum"] as? [String])
        #expect(actions == ["list", "open", "create", "close"])
        #expect(!actions.contains("delete"))
    }

    @Test func rejectsDeleteAndActionSpecificFields() async {
        let harness = ToolHarness()

        let delete = await harness.runRaw("manage_project", args: ["action": "delete"])
        #expect(delete.isError)
        #expect(ToolHarness.textOf(delete).contains("Unknown project action"))

        let invalidList = await harness.runRaw("manage_project", args: ["action": "list", "name": "Example"])
        #expect(invalidList.isError)
        #expect(ToolHarness.textOf(invalidList).contains("Allowed: none"))
    }

    @Test func rejectsInvalidAndConflictingSelectors() async {
        let harness = ToolHarness()
        let cases: [[String: Any]] = [
            ["action": "open"],
            ["action": "open", "name": "A", "path": "/tmp/A.palmier"],
            ["action": "close", "id": "A", "path": "/tmp/A.palmier"],
            ["action": "open", "name": ""],
            ["action": "close", "path": "   "],
            ["action": "open", "id": "not-a-project-id"],
            ["action": "create", "name": 42],
        ]

        for args in cases {
            let result = await harness.runRaw("manage_project", args: args)
            #expect(result.isError, "Expected rejection for \(args)")
        }
    }

    @Test func mcpSessionPinsProjectWhileInAppChatStaysLocal() async {
        let first = VideoProject()
        first.editorViewModel.timeline.name = "First Session"
        let second = VideoProject()
        let controller = NSDocumentController.shared
        controller.addDocument(first)
        controller.addDocument(second)
        defer {
            controller.removeDocument(first)
            controller.removeDocument(second)
        }

        var visible: VideoProject? = first
        let service = MCPService(projectProvider: { visible })
        let firstSession = service.makeSessionToolExecutor()
        #expect(ToolHarness.textOf(await firstSession.execute(name: "get_timeline", args: [:])).contains("First Session"))

        visible = second
        #expect(ToolHarness.textOf(await firstSession.execute(name: "get_timeline", args: [:])).contains("First Session"))
        #expect((await firstSession.execute(name: "create_timeline", args: ["name": "Blocked"])).isError)
        #expect(!(await ToolExecutor(editor: first.editorViewModel).execute(name: "create_timeline", args: ["name": "In-App"])).isError)
    }
}
