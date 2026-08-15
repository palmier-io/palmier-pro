import Foundation
import Testing
@testable import PalmierPro

@MainActor
private final class SkillToolHarness {
    let editor = EditorViewModel()
    let directory: URL
    let store: SkillStore
    let executor: ToolExecutor

    init(directory: URL) {
        self.directory = directory
        let store = SkillStore(directory: directory)
        self.store = store
        executor = ToolExecutor(editor: editor, skillStore: store)
    }

    func call(
        _ action: String,
        id: String? = nil,
        name: String? = nil,
        description: String? = nil,
        instructions: String? = nil,
        source: String = "agent"
    ) async -> ToolResult {
        var args: [String: Any] = ["action": action]
        if let id { args["id"] = id }
        if let name { args["name"] = name }
        if let description = description ?? (action == "create" ? "Use this skill." : nil) {
            args["description"] = description
        }
        if let instructions = instructions ?? (action == "create" ? "Follow the workflow." : nil) {
            args["instructions"] = instructions
        }
        return await executor.execute(name: "manage_skills", args: args, source: source)
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
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        #expect(properties["action"]?["enum"] as? [String] == ["create", "update", "remove"])
        #expect(Set(properties.keys) == ["action", "id", "name", "description", "instructions"])
    }

    @Test func createUpdateAndRemoveSkill() async throws {
        try await withHarness { harness in
            let initialInstructions = "## Workflow\nRemove pauses, then remove filler words."
            let created = await harness.call(
                "create",
                name: "Interview Cleanup",
                description: "Tighten spoken interviews.",
                instructions: initialInstructions
            )
            let createdJSON = try resultJSON(created)
            let createdSkill = try #require(createdJSON["skill"] as? [String: Any])
            #expect(createdJSON["status"] as? String == "created")
            #expect(createdSkill["id"] as? String == "interview-cleanup")
            #expect(harness.store.body(for: "interview-cleanup") == initialInstructions)

            let repeated = await harness.call(
                "create",
                name: "Interview Cleanup",
                description: "Tighten spoken interviews.",
                instructions: initialInstructions
            )
            #expect(try resultJSON(repeated)["status"] as? String == "unchanged")
            #expect(harness.store.skills.count == 1)

            let updated = await harness.call(
                "update",
                id: "interview-cleanup",
                description: "Tighten interviews while preserving intent.",
                instructions: "## Workflow\nRemove pauses conservatively."
            )
            let updatedJSON = try resultJSON(updated)
            #expect(updatedJSON["status"] as? String == "updated")
            #expect(updatedJSON["changed"] as? [String] == ["description", "instructions"])
            #expect(harness.store.body(for: "interview-cleanup") == "## Workflow\nRemove pauses conservatively.")

            let unchanged = await harness.call(
                "update",
                id: "interview-cleanup",
                description: "Tighten interviews while preserving intent."
            )
            #expect(try resultJSON(unchanged)["status"] as? String == "unchanged")

            let removed = await harness.call("remove", id: "interview-cleanup")
            #expect(try resultJSON(removed)["status"] as? String == "removed")
            #expect(harness.store.skills.isEmpty)
        }
    }

    @Test func removingLocalSkillSuppressesMatchingCatalogID() async throws {
        try await withHarness { harness in
            #expect(!(await harness.call("create", name: "Catalog Collision")).isError)
            #expect(!(await harness.call("remove", id: "catalog-collision")).isError)
            let ledger = try #require(await persistedLedger(in: harness.directory))
            #expect(ledger.suppressed.contains("catalog-collision"))
        }
    }

    @Test func ledgerWriteFailureLeavesSkillIntact() async throws {
        try await withHarness { harness in
            #expect(!(await harness.call("create", name: "Protected Skill")).isError)
            try await blockLedgerWrites(in: harness.directory)
            #expect((await harness.call("remove", id: "protected-skill")).isError)
            #expect(await skillFileExists(id: "protected-skill", in: harness.directory))
        }
    }

    @Test func folderRemovalFailureRestoresLedger() async throws {
        try await withHarness { harness in
            let missing = Skill(
                id: "missing",
                name: "Missing",
                description: "Missing fixture.",
                path: harness.directory.appendingPathComponent("missing/SKILL.md")
            )
            #expect(!(await harness.store.delete(missing)))
            let ledger = try #require(await persistedLedger(in: harness.directory))
            #expect(ledger == SkillLedger())
        }
    }

    @Test func rejectsInvalidUpdatesAndMCPCalls() async throws {
        try await withHarness { harness in
            let invalidUpdate = await harness.call("update", id: "missing")
            #expect(invalidUpdate.isError)
            #expect(resultText(invalidUpdate).contains("at least one"))

            let mcpCreate = await harness.call("create", name: "Private Workflow", source: "mcp")
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
    private func persistedLedger(in directory: URL) async -> SkillLedger? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".installed.json")) else {
            return nil
        }
        return SkillStore.decodeLedger(data)
    }

    @concurrent
    private func blockLedgerWrites(in directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".installed.json", isDirectory: true),
            withIntermediateDirectories: false
        )
    }

    @concurrent
    private func skillFileExists(id: String, in directory: URL) async -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(id).appendingPathComponent("SKILL.md").path
        )
    }

    @concurrent
    private func removeDirectory(_ directory: URL) async {
        try? FileManager.default.removeItem(at: directory)
    }
}
