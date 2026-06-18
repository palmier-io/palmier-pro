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
        #expect(prompt.contains("USER: Trim first clip"))
        #expect(prompt.contains("ASSISTANT: Done"))
    }

    @Test func codexArgumentsUseSchemaFileAndIgnoreProjectRules() {
        let schemaURL = URL(fileURLWithPath: "/tmp/schema.json")
        let lastURL = URL(fileURLWithPath: "/tmp/last.json")

        let args = CodexCLIClient.codexArguments(schemaURL: schemaURL, lastMessageURL: lastURL)

        #expect(args.contains("--ignore-rules"))
        #expect(args.contains("approval_policy=\"never\""))
        #expect(args.pair(after: "--sandbox") == "read-only")
        #expect(args.pair(after: "--output-schema") == schemaURL.path)
        #expect(args.pair(after: "--output-last-message") == lastURL.path)
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
}

private extension Array where Element == String {
    func pair(after flag: String) -> String? {
        guard let index = firstIndex(of: flag), indices.contains(index + 1) else { return nil }
        return self[index + 1]
    }
}
