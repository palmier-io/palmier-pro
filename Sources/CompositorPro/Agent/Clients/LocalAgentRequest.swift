import Foundation

struct LocalAgentRequest: Sendable {
    let directory: URL
    let arguments: [String]
    let input: Data

    @concurrent
    static func prepare(
        harness: LocalAgentHarness,
        effort: AgentReasoningEffort,
        system: String,
        messages: [AgentRequestMessage],
        endpoint: URL,
        modelID: String? = nil
    ) async throws -> Self {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compositor-agent-\(UUID().uuidString)", isDirectory: true)
        do {
            let configDirectory = directory.appendingPathComponent(".agents", isDirectory: true)
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let agyConfig = ["mcpServers": ["compositor-pro": ["serverUrl": endpoint.absoluteString]]]
            try JSONSerialization.data(withJSONObject: agyConfig).write(
                to: configDirectory.appendingPathComponent("mcp_config.json"), options: .atomic
            )
            let config = directory.appendingPathComponent("mcp.json")
            try JSONSerialization.data(withJSONObject: [
                "mcpServers": ["compositor-pro": ["type": "http", "url": endpoint.absoluteString]]
            ]).write(to: config, options: .atomic)

            var transcript = [system, "Use the compositor-pro MCP tools to inspect and edit the project bound to this connection. Follow the user's request and verify tool results. The following conversation is context; answer its latest user message."]
            var imageCount = 0
            var imageBytes = 0
            for message in messages {
                try Task.checkCancellation()
                var content: [String] = []
                for block in message.content {
                    switch block {
                    case .content(.text(let text)):
                        content.append(text)
                    case .image(let base64, let mediaType):
                        let suffix: String
                        switch mediaType {
                        case "image/png": suffix = "png"
                        case "image/jpeg": suffix = "jpg"
                        case "image/webp": suffix = "webp"
                        case "image/gif": suffix = "gif"
                        default: throw LocalAgentFailure.invalidInput
                        }
                        guard imageCount < 16, base64.utf8.count <= 8_388_608,
                              let data = Data(base64Encoded: base64), data.count <= 16_777_216 - imageBytes
                        else { throw LocalAgentFailure.invalidInput }
                        imageBytes += data.count
                        imageCount += 1
                        let imageURL = directory.appendingPathComponent("reference-\(imageCount).\(suffix)")
                        try data.write(to: imageURL, options: .atomic)
                        content.append("Image reference: \(imageURL.path)")
                    default:
                        break
                    }
                }
                if !content.isEmpty { transcript.append("\(message.role.rawValue):\n" + content.joined(separator: "\n")) }
            }
            let prompt = transcript.joined(separator: "\n\n")
            guard prompt.utf8.count <= 2_097_152 else { throw LocalAgentFailure.invalidInput }
            try Task.checkCancellation()
            var arguments: [String]
            let input: Data
            switch harness {
            case .antigravity:
                let settings = #"{"permissions":{"allow":["mcp(compositor-pro/*)"]}}"#
                arguments = ["--input-format", "stream-json", "--output-format", "stream-json",
                             "--add-dir", directory.path, "--mode", "auto", "--sandbox", "--effort", effort.rawValue,
                             "--settings", settings]
                input = try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["content": prompt]]) + Data([10])
            case .claudeCode:
                arguments = ["--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                             "--restricted", "--tools", "Read", "--allowedTools", "mcp__compositor-pro__*,Read",
                             "--strict-mcp-config", "--mcp-config", config.path, "--effort", effort.rawValue]
                input = Data(prompt.utf8)
            case .codex:
                arguments = ["--ask-for-approval", "on-request", "--config",
                             "mcp_servers={compositor-pro={url=\"\(endpoint.absoluteString)\"}}",
                             "--config", "model_reasoning_effort=\"\(effort.rawValue)\"",
                             "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "-"]
                input = Data(prompt.utf8)
            }
            if let modelID = try LocalAgentHarness.normalizedModelID(modelID ?? "") {
                arguments.insert(contentsOf: ["--model", modelID], at: 0)
            }
            return Self(directory: directory, arguments: arguments, input: input)
        } catch {
            let failure = (error as? LocalAgentFailure) ?? (error is CancellationError ? .cancelled : .setupFailed)
            do {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            } catch { throw LocalAgentFailure.cleanupAfterFailure(failure) }
            if error is CancellationError || error is LocalAgentFailure { throw error }
            throw LocalAgentFailure.setupFailed
        }
    }

    @concurrent func cleanup() async throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw LocalAgentFailure.cleanupFailed }
    }
}
