import Foundation
import Testing
@testable import PalmierPro

@Suite("CodexCLIClient")
struct CodexCLIClientTests {
    @Test func promptRendersConversationForCodexExec() {
        let prompt = CodexCLIClient.prompt(
            system: "System instructions",
            messages: [
                AnthropicMessage(role: .user, content: [["type": "text", "text": "Trim first clip"]]),
                AnthropicMessage(role: .assistant, content: [["type": "text", "text": "Done"]])
            ]
        )

        #expect(prompt.contains("System instructions"))
        #expect(prompt.contains("Reply as JSON matching the provided schema"))
        #expect(prompt.contains("text must be a non-empty user-visible response"))
        #expect(prompt.contains("USER: Trim first clip"))
        #expect(prompt.contains("ASSISTANT: Done"))
    }

    @Test func codexArgumentsUseSchemaFileAndIgnoreProjectRules() {
        let schemaURL = URL(fileURLWithPath: "/tmp/schema.json")
        let lastURL = URL(fileURLWithPath: "/tmp/last.json")

        let args = CodexCLIClient.codexArguments(schemaURL: schemaURL, lastMessageURL: lastURL)

        #expect(args.contains("--ignore-rules"))
        #expect(args.pair(after: "-m") == nil)
        #expect(args.contains("approval_policy=\"never\""))
        #expect(args.pair(after: "--sandbox") == "read-only")
        #expect(args.pair(after: "--output-schema") == schemaURL.path)
        #expect(args.pair(after: "--output-last-message") == lastURL.path)
    }

    @Test func codexArgumentsPassSelectedModel() {
        let schemaURL = URL(fileURLWithPath: "/tmp/schema.json")
        let lastURL = URL(fileURLWithPath: "/tmp/last.json")
        let args = CodexCLIClient.codexArguments(
            modelSlug: "gpt-5.5",
            schemaURL: schemaURL,
            lastMessageURL: lastURL
        )
        #expect(args.pair(after: "-m") == "gpt-5.5")
    }

    @Test func codexArgumentsPassSelectedReasoning() {
        let schemaURL = URL(fileURLWithPath: "/tmp/schema.json")
        let lastURL = URL(fileURLWithPath: "/tmp/last.json")
        let args = CodexCLIClient.codexArguments(
            reasoningEffort: "xhigh",
            schemaURL: schemaURL,
            lastMessageURL: lastURL
        )
        #expect(args.contains("model_reasoning_effort=\"xhigh\""))
    }

    @Test func codexModelCatalogDecodesDynamicModelsAndReasoning() throws {
        let data = Data("""
        {
          "models": [
            {
              "slug": "gpt-5.5",
              "display_name": "GPT-5.5",
              "visibility": "list",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                { "effort": "low", "description": "Fast" },
                { "effort": "xhigh", "description": "Deep" }
              ]
            },
            {
              "slug": "codex-auto-review",
              "display_name": "Codex Auto Review",
              "visibility": "hide",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": []
            }
          ]
        }
        """.utf8)
        let models = try CodexCLIClient.visibleModels(from: data)
        #expect(models.map(\.slug) == ["gpt-5.5"])
        #expect(models.first?.supportedReasoningLevels.last?.displayName == "Extra High")
    }

    @Test func executableLookupUsesPathEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let codex = dir.appendingPathComponent("codex")
        try Data().write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        #expect(CodexCLIClient.executableURL(environment: ["PATH": dir.path]) == codex)
    }

    @Test func candidatePathsIncludeUserLocalInstallLocations() {
        let paths = CodexCLIClient.candidatePaths(environment: ["HOME": "/tmp/palmier-home"])

        #expect(paths.contains("/tmp/palmier-home/.npm-global/bin/codex"))
        #expect(paths.contains("/tmp/palmier-home/.local/bin/codex"))
    }

    @Test func responseJSONMapsToAgentStreamEvents() throws {
        let data = Data("""
        {
          "text": "Done",
          "tool_calls": [
            { "id": "call_1", "name": "move_clips", "input_json": "{\\"clipIds\\":[\\"c1\\"]}" }
          ],
          "stop_reason": "tool_use"
        }
        """.utf8)

        let events = try CodexCLIClient.events(from: data)

        #expect(events.count == 3)
        if case .textDelta("Done") = events[0] {} else {
            Issue.record("Expected text delta")
        }
        if case let .toolUseComplete(id, name, inputJSON) = events[1] {
            #expect(id == "call_1")
            #expect(name == "move_clips")
            #expect(inputJSON == "{\"clipIds\":[\"c1\"]}")
        } else {
            Issue.record("Expected tool use")
        }
        if case .messageStop(.toolUse) = events[2] {} else {
            Issue.record("Expected tool_use stop")
        }
    }

    @Test func emptyTextWithoutToolCallsThrows() {
        let data = Data("""

        {
          "text": "   ",
          "tool_calls": [],
          "stop_reason": "end_turn"
        }

        """.utf8)

        #expect(throws: PalmierClientError.self) {
            try CodexCLIClient.events(from: data)
        }
    }

    @Test func failureMessageHidesCodexWarningNoise() {
        let stderr = """
        2026-06-18T22:36:21.838174Z WARN codex_features: unknown feature key in config: ghost_commit
        2026-06-18T22:36:22.082977Z WARN codex_rollout::list: state db discrepancy
        """

        let message = CodexCLIClient.failureMessage(status: 1, stderr: stderr)

        #expect(message.contains("Codex CLI failed (1)"))
        #expect(message.contains("Codex CLI returned local warnings"))
        #expect(!message.contains("ghost_commit"))
    }
}

private extension Array where Element == String {
    func pair(after flag: String) -> String? {
        guard let index = firstIndex(of: flag), indices.contains(index + 1) else { return nil }
        return self[index + 1]
    }
}
