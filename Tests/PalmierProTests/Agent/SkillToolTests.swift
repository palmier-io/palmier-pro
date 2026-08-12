import Foundation
import Testing
@testable import PalmierPro

@MainActor
private final class SkillToolHarness {
    let editor = EditorViewModel()
    let store: SkillStore
    let executor: ToolExecutor

    init(directory: URL) {
        let store = SkillStore(directory: directory)
        self.store = store
        executor = ToolExecutor(editor: editor, skillStore: store)
    }

    func run(
        _ name: String,
        args: [String: Any],
        source: String = "agent"
    ) async -> ToolResult {
        await executor.execute(name: name, args: args, source: source)
    }
}

@Suite("In-app skill tools")
@MainActor
struct SkillToolTests {
    @Test func schemasAreExposedOnlyToTheInAppAgent() throws {
        let inAppNames = Set(ToolDefinitions.inAppAgent.map(\.name))
        let mcpNames = Set(ToolDefinitions.mcpServer.map(\.name))

        #expect(inAppNames.contains(.manageSkills))
        #expect(!mcpNames.contains(.manageSkills))

        let tool = try #require(ToolDefinitions.inAppAgent.first { $0.name == .manageSkills })
        #expect(tool.inputSchema["required"] as? [String] == ["action"])
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        #expect(properties["action"]?["enum"] as? [String] == ["create", "update", "remove"])
        #expect(Set(properties.keys) == ["action", "id", "name", "description", "instructions"])
    }

    @Test func createUpdateAndRemoveSkill() async throws {
        try await withHarness { harness in
            let createArgs = [
                "action": "create",
                "name": "Interview Cleanup",
                "description": "Tighten spoken interviews.",
                "instructions": "## Workflow\nRemove pauses, then remove filler words.",
            ]
            let created = await harness.run("manage_skills", args: createArgs)
            let createdJSON = try resultJSON(created)
            let createdSkill = try #require(createdJSON["skill"] as? [String: Any])

            #expect(createdJSON["status"] as? String == "created")
            #expect(createdSkill["id"] as? String == "interview-cleanup")
            #expect(harness.store.body(for: "interview-cleanup") == createArgs["instructions"])

            let repeated = await harness.run("manage_skills", args: createArgs)
            #expect(try resultJSON(repeated)["status"] as? String == "unchanged")
            #expect(harness.store.skills.count == 1)

            let updated = await harness.run("manage_skills", args: [
                "action": "update",
                "id": "interview-cleanup",
                "description": "Tighten interviews while preserving intent.",
                "instructions": "## Workflow\nRemove pauses conservatively.",
            ])
            let updatedJSON = try resultJSON(updated)
            #expect(updatedJSON["status"] as? String == "updated")
            #expect(updatedJSON["changed"] as? [String] == ["description", "instructions"])
            #expect(harness.store.skills.first?.description == "Tighten interviews while preserving intent.")
            #expect(harness.store.body(for: "interview-cleanup") == "## Workflow\nRemove pauses conservatively.")

            let unchanged = await harness.run("manage_skills", args: [
                "action": "update",
                "id": "interview-cleanup",
                "description": "Tighten interviews while preserving intent.",
            ])
            #expect(try resultJSON(unchanged)["status"] as? String == "unchanged")

            let removed = await harness.run("manage_skills", args: [
                "action": "remove",
                "id": "interview-cleanup",
            ])
            #expect(try resultJSON(removed)["status"] as? String == "removed")
            #expect(harness.store.skills.isEmpty)
        }
    }

    @Test func rejectsInvalidUpdatesAndMCPCalls() async throws {
        try await withHarness { harness in
            let invalidUpdate = await harness.run("manage_skills", args: [
                "action": "update",
                "id": "missing",
            ])
            #expect(invalidUpdate.isError)
            #expect(resultText(invalidUpdate).contains("at least one"))

            let mcpCreate = await harness.run("manage_skills", args: [
                "action": "create",
                "name": "Private workflow",
                "description": "Use a private workflow.",
                "instructions": "Do the work.",
            ], source: "mcp")
            #expect(mcpCreate.isError)
            #expect(resultText(mcpCreate).contains("Unknown tool"))
            #expect(harness.store.skills.isEmpty)
        }
    }

    private func withHarness(
        _ operation: @MainActor (SkillToolHarness) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-skill-tools-\(UUID().uuidString)", isDirectory: true)
        let harness = SkillToolHarness(directory: directory)
        await harness.store.reloadSkills()
        do {
            try await operation(harness)
        } catch {
            await removeDirectory(directory)
            throw error
        }
        await removeDirectory(directory)
    }

    private func resultJSON(_ result: ToolResult) throws -> [String: Any] {
        #expect(!result.isError, "\(resultText(result))")
        let data = Data(resultText(result).utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func resultText(_ result: ToolResult) -> String {
        guard case .text(let text) = result.content.first else { return "" }
        return text
    }

    @concurrent
    private func removeDirectory(_ directory: URL) async {
        try? FileManager.default.removeItem(at: directory)
    }
}
