import Foundation

struct CodexCLIClient: AgentClient {
    let modelSlug: String?
    let reasoningEffort: String?

    init(modelSlug: String? = nil, reasoningEffort: String? = nil) {
        self.modelSlug = modelSlug
        self.reasoningEffort = reasoningEffort
    }

    static var isAvailable: Bool { executableURL != nil }

    static var executableURL: URL? {
        executableURL(environment: ProcessInfo.processInfo.environment)
    }

    static func executableURL(environment: [String: String]) -> URL? {
        let fm = FileManager.default
        for path in candidatePaths(environment: environment) where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func candidatePaths(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let homePaths = [
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex"
        ]
        let defaults = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        let pathEntries = environment["PATH", default: ""]
            .split(separator: ":")
            .map { String($0) + "/codex" }
        return pathEntries + homePaths + defaults
    }

    static func loadModelCatalog() throws -> [CodexModel] {
        guard let executableURL else {
            throw PalmierClientError.upstream("Codex CLI not found. Install Codex or open Codex.app.")
        }

        let fm = FileManager.default
        let outputURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let errorURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = fm.createFile(atPath: outputURL.path, contents: nil)
        _ = fm.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outputURL)
            try? fm.removeItem(at: errorURL)
        }

        let process = Process()
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.executableURL = executableURL
        process.arguments = ["debug", "models"]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        try? stdout.close()
        try? stderr.close()
        let output = try Data(contentsOf: outputURL)
        if process.terminationStatus == 0 {
            return try visibleModels(from: output)
        }

        let stderrText = String(data: (try? Data(contentsOf: errorURL)) ?? Data(), encoding: .utf8) ?? ""
        throw PalmierClientError.upstream(Self.failureMessage(status: process.terminationStatus, stderr: stderrText))
    }

    static func visibleModels(from data: Data) throws -> [CodexModel] {
        try JSONDecoder().decode(CodexModelCatalog.self, from: data)
            .models
            .filter { $0.visibility != "hide" }
    }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            let task = Task {
                do {
                    let response = try Self.run(
                        process: process,
                        modelSlug: modelSlug,
                        reasoningEffort: reasoningEffort,
                        prompt: Self.prompt(system: system, tools: tools, messages: messages)
                    )
                    for event in Self.events(from: response) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                process.terminate()
                task.cancel()
            }
        }
    }

    private static func run(
        process: Process,
        modelSlug: String?,
        reasoningEffort: String?,
        prompt: String
    ) throws -> CodexResponse {
        guard let executableURL else {
            throw PalmierClientError.upstream("Codex CLI not found. Install Codex or open Codex.app.")
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lastMessage = dir.appendingPathComponent("last.txt")
        let stdoutURL = dir.appendingPathComponent("stdout.jsonl")
        let stderrURL = dir.appendingPathComponent("stderr.log")
        let schemaURL = dir.appendingPathComponent("schema.json")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        try Data(Self.outputSchema.utf8).write(to: schemaURL)

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let stdin = Pipe()
        process.executableURL = executableURL
        process.arguments = Self.codexArguments(
            modelSlug: modelSlug,
            reasoningEffort: reasoningEffort,
            schemaURL: schemaURL,
            lastMessageURL: lastMessage
        )
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if let data = try? Data(contentsOf: lastMessage), !data.isEmpty,
           let response = try? JSONDecoder().decode(CodexResponse.self, from: data) {
            return response
        }

        guard process.terminationStatus == 0 else {
            throw PalmierClientError.upstream(Self.failureMessage(
                status: process.terminationStatus,
                stderr: stderrText
            ))
        }

        throw PalmierClientError.upstream("Codex CLI returned no response.")
    }

    static func failureMessage(status: Int32, stderr: String) -> String {
        let message = UserFacingError.message(String(stderr.prefix(500)))
        return "Codex CLI failed (\(status)): \(message)"
    }

    static func events(from data: Data) throws -> [AnthropicStreamEvent] {
        let response = try JSONDecoder().decode(CodexResponse.self, from: data)
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           response.toolCalls.isEmpty {
            throw PalmierClientError.upstream("Codex CLI returned an empty response.")
        }
        return events(from: response)
    }

    private static func events(from response: CodexResponse) -> [AnthropicStreamEvent] {
        var events: [AnthropicStreamEvent] = []
        if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(.textDelta(response.text))
        }
        events += response.toolCalls.map {
            .toolUseComplete(id: $0.id, name: $0.name, inputJSON: $0.inputJSON)
        }
        events.append(.messageStop(stopReason: response.stopReason))
        return events
    }

    static func codexArguments(
        modelSlug: String? = nil,
        reasoningEffort: String? = nil,
        schemaURL: URL,
        lastMessageURL: URL
    ) -> [String] {
        var args = [
            "exec",
            "--json",
            "--ephemeral",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-c", "approval_policy=\"never\"",
            "--output-schema", schemaURL.path,
            "--output-last-message", lastMessageURL.path,
            "-"
        ]
        if let value = modelSlug?.nilIfEmpty {
            args.insert(contentsOf: ["-m", value], at: 1)
        }
        if let effort = reasoningEffort?.nilIfEmpty {
            args.insert(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""], at: 1)
        }
        return args
    }

    static func prompt(
        system: String,
        tools: [AnthropicToolSchema] = [],
        messages: [AnthropicMessage]
    ) -> String {
        """
        \(system)

        You are running inside Palmier Pro through Codex CLI.
        Reply as JSON matching the provided schema. To act on the timeline, choose tool calls from Available tools.
        If you do not choose tool calls, text must be a non-empty user-visible response.
        Set stop_reason to tool_use when tool_calls is non-empty, otherwise end_turn.
        input_json must be a valid JSON object string.

        Available tools:
        \(toolsJSON(tools))

        Conversation:
        \(messages.map(render).joined(separator: "\n\n"))
        """
    }

    private static func render(_ message: AnthropicMessage) -> String {
        let body = message.content.compactMap(renderBlock).joined(separator: "\n")
        return "\(message.role.rawValue.uppercased()): \(body)"
    }

    private static func renderBlock(_ block: [String: Any]) -> String? {
        switch block["type"] as? String {
        case "text":
            return block["text"] as? String
        case "tool_result":
            return "Tool result: \(block["content"] ?? "")"
        case "tool_use":
            return "Tool request: \(block["name"] ?? "") \(block["input"] ?? "")"
        case "image":
            return "[Image omitted by Codex CLI chat bridge. Use Palmier inspect/search tools if needed.]"
        default:
            return nil
        }
    }

    private static func toolsJSON(_ tools: [AnthropicToolSchema]) -> String {
        let value = tools.map {
            [
                "name": $0.name,
                "description": $0.description,
                "input_schema": $0.inputSchema
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static let outputSchema = """
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "text": { "type": "string" },
        "tool_calls": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "id": { "type": "string" },
              "name": { "type": "string" },
              "input_json": { "type": "string" }
            },
            "required": ["id", "name", "input_json"]
          }
        },
        "stop_reason": { "type": "string", "enum": ["end_turn", "tool_use"] }
      },
      "required": ["text", "tool_calls", "stop_reason"]
    }
    """
}

private struct CodexResponse: Decodable {
    let text: String
    let toolCalls: [ToolCall]
    let stopReason: AnthropicStopReason

    private enum CodingKeys: String, CodingKey {
        case text
        case toolCalls = "tool_calls"
        case stopReason = "stop_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        toolCalls = try c.decode([ToolCall].self, forKey: .toolCalls)
        let raw = try c.decode(String.self, forKey: .stopReason)
        stopReason = AnthropicStopReason(rawValue: raw) ?? .other
    }

    struct ToolCall: Decodable {
        let id: String
        let name: String
        let inputJSON: String

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case inputJSON = "input_json"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
