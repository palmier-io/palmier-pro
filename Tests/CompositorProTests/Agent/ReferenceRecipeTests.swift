import Foundation
import MCP
import Testing
@testable import CompositorPro

enum ReferenceRecipeFixtures {
    static func recipe() -> ReferenceRecipe {
        ReferenceRecipe(
            title: "Documentary reference", sourceURL: "https://example.invalid/reference",
            sourceDurationSeconds: 1260, coverage: [.captions, .stills],
            cues: [
                .init(cueId: "arc", kind: .narrativeArc, evidence: .observed, startSeconds: 0, endSeconds: 30,
                      observation: "The opening introduces a dependency before its history.",
                      editorialRule: "Establish the consequence before explaining the mechanism."),
                .init(cueId: "map", kind: .sceneFamily, evidence: .observed, startSeconds: 30, endSeconds: 60,
                      observation: "Regional maps connect a place to its industry.",
                      editorialRule: "Use geographic context when the argument depends on location."),
                .init(cueId: "motion", kind: .motion, evidence: .unverified,
                      observation: "Samples do not establish continuous camera movement.",
                      editorialRule: "Do not claim reference motion was verified."),
            ],
            limitations: "Captions and sampled stills only; continuous motion and audible mix unverified."
        )
    }
}

struct ReferenceRecipeTests {
    @Test(arguments: ["duplicate", "empty coverage", "duplicate coverage", "duration", "timestamp", "missing timestamp", "motion", "audio", "empty rule"])
    func invalidRecipesAreRejected(caseName: String) {
        var recipe = ReferenceRecipeFixtures.recipe()
        switch caseName {
        case "duplicate": recipe.cues.append(recipe.cues[0])
        case "empty coverage": recipe.coverage = []
        case "duplicate coverage": recipe.coverage.append(.stills)
        case "duration": recipe.sourceDurationSeconds = .infinity
        case "timestamp": recipe.cues[0].endSeconds = 1261
        case "missing timestamp": recipe.cues[0].endSeconds = nil
        case "motion": recipe.cues[0].kind = .motion
        case "audio": recipe.cues[0].kind = .audio
        default: recipe.cues[0].editorialRule = " "
        }
        #expect(throws: EditPlanValidationError.self) { try recipe.validated() }
    }

    @Test func recipeUsesRequireKnownUniqueCuesAndRationale() throws {
        let recipe = try ReferenceRecipeFixtures.recipe().validated()
        for use in [
            ReferenceRecipeUse(cueIds: ["missing"], rationale: "Reason"),
            ReferenceRecipeUse(cueIds: ["arc", "arc"], rationale: "Reason"),
            ReferenceRecipeUse(cueIds: [], rationale: "Reason"),
            ReferenceRecipeUse(cueIds: ["arc"], rationale: " "),
        ] {
            #expect(throws: EditPlanValidationError.self) { try use.validated(recipe: recipe) }
        }
        #expect(throws: EditPlanValidationError.self) {
            try ReferenceRecipeUse(cueIds: ["arc"], rationale: "Reason").validated(recipe: nil)
        }
    }
}

@Suite("Reference recipe MCP")
@MainActor
struct ReferenceRecipeMCPTests {
    @Test func suppliedRecipeKeepsOutlineRationaleRuntimePersistenceAndUndo() async throws {
        let harness = ToolHarness()
        let server = Server(name: "reference-recipe", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "reference-recipe-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "plan_edit" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["plan"]?.objectValue?["properties"]?.objectValue)
            #expect(properties["referenceRecipe"] != nil)
            let recipe = ReferenceRecipeFixtures.recipe()
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"), "plan": .object([
                    "planId": .string("recipe-plan"), "name": .string("90-second explainer"),
                    "referenceRecipe": try Value(recipe),
                    "sections": .array([.object([
                        "sectionId": .string("hook"), "title": .string("Why it matters"),
                        "startFrame": .int(0), "endFrame": .int(2700),
                        "referenceUse": try Value(ReferenceRecipeUse(cueIds: ["arc"], rationale: "Lead with the dependency, not chronology.")),
                    ])]),
                    "shots": .array([.object([
                        "shotId": .string("geography"), "title": .string("Regional context"),
                        "startFrame": .int(0), "endFrame": .int(300),
                        "referenceUse": try Value(ReferenceRecipeUse(cueIds: ["map"], rationale: "Show where the industrial dependency originates.")),
                    ])]),
                ]),
            ])
            let createdText = try text(created.content)
            #expect(created.isError != true, "\(createdText)")
            let approved = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("status"), "planId": .string("recipe-plan"), "status": .string("approved"),
            ])
            #expect(approved.isError != true)
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let before = try #require(harness.editor.editPlan(id: "recipe-plan"))
            #expect(before.sections.first?.endFrame == 2700)
            #expect(before.referenceRecipe?.sourceDurationSeconds == 1260)
            var unchanged = recipe
            unchanged.title = " \(recipe.title) "
            let normalized = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string("recipe-plan"),
                "patch": .object(["referenceRecipe": try Value(unchanged)]),
            ])
            #expect(normalized.isError != true)
            #expect(try json(normalized.content)["noOp"] as? Bool == true)
            #expect(!undo.canUndo)
            let snapshot = before
            let persisted = try await Task.detached {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let timeline = Fixtures.timeline()
                let file = ProjectFile(timelines: [timeline], activeTimelineId: timeline.id, openTimelineIds: [timeline.id])
                try JSONEncoder().encode(file).write(to: directory.appendingPathComponent(Project.timelineFilename))
                try EditPlanStore.writePackageFile(try EditPlanStore.encode([snapshot]), to: directory, sourceURL: nil)
                return try VideoProject.readProjectPackage(at: directory).plans
            }.value
            #expect(persisted?.first?.referenceRecipe == recipe)
            #expect(persisted?.first?.sections == before.sections)
            #expect(persisted?.first?.shots == before.shots)

            var broken = recipe
            broken.cues.removeFirst()
            let refused = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string("recipe-plan"),
                "patch": .object(["referenceRecipe": try Value(broken)]),
            ])
            #expect(refused.isError == true)
            #expect(harness.editor.editPlan(id: "recipe-plan") == before)
            #expect(!undo.canUndo)
            var unknown = try #require(try Value(recipe).objectValue)
            unknown["downloadReference"] = .bool(true)
            let unknownField = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("update"), "planId": .string("recipe-plan"),
                "patch": .object(["referenceRecipe": .object(unknown)]),
            ])
            #expect(unknownField.isError == true)
            #expect(harness.editor.editPlan(id: "recipe-plan") == before)
            #expect(!undo.canUndo)

            var revised = recipe
            revised.cues[0].editorialRule = "Explain the present consequence before its history."
            let arguments: [String: Value] = [
                "action": .string("update"), "planId": .string("recipe-plan"),
                "patch": .object(["referenceRecipe": try Value(revised)]),
            ]
            let updated = try await client.callTool(name: "plan_edit", arguments: arguments)
            let updatedText = try text(updated.content)
            #expect(updated.isError != true, "\(updatedText)")
            let repeated = try await client.callTool(name: "plan_edit", arguments: arguments)
            #expect(try json(repeated.content)["noOp"] as? Bool == true)
            let read = try await client.callTool(name: "plan_edit", arguments: ["action": .string("read"), "planId": .string("recipe-plan")])
            let receipt = try json(read.content)
            #expect((receipt["referenceRecipe"] as? [String: Any])?["limitations"] as? String == recipe.limitations)
            #expect((receipt["sections"] as? [[String: Any]])?.first?["referenceUse"] != nil)
            let undone = try await client.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(harness.editor.editPlan(id: "recipe-plan") == before)
            #expect(!undo.canUndo)
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
