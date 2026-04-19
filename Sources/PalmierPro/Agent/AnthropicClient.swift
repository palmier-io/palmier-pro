import Foundation

enum AnthropicKeychain {
    private static let filename = "anthropic-credentials"
    static func save(_ key: String) { FileCredentialStore.save(key, filename: filename) }
    static func load() -> String? { FileCredentialStore.load(filename: filename) }
    static func delete() { FileCredentialStore.delete(filename: filename) }
}

enum AnthropicModel: String, CaseIterable, Sendable {
    case sonnet46 = "claude-sonnet-4-6"
    case opus47 = "claude-opus-4-7"
    case haiku45 = "claude-haiku-4-5-20251001"

    var displayName: String {
        switch self {
        case .sonnet46: "Sonnet 4.6"
        case .opus47: "Opus 4.7"
        case .haiku45: "Haiku 4.5"
        }
    }
}

enum AnthropicStopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case other
}

struct AnthropicMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [[String: Any]]
}

struct AnthropicToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum AnthropicStreamEvent: @unchecked Sendable {
    case textDelta(String)
    case toolUseComplete(id: String, name: String, input: [String: Any])
    case messageStop(stopReason: AnthropicStopReason)
}

enum AnthropicClientError: LocalizedError {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No Anthropic API key is set."
        case .httpError(let status, let body): "Anthropic API error (\(status)): \(body.prefix(500))"
        case .streamError(let msg): "Stream error: \(msg)"
        }
    }
}

struct AnthropicClient: Sendable {
    let apiKey: String
    let model: AnthropicModel
    var maxTokens: Int = 8192

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AnthropicClientError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: buildBody(
            system: system, tools: tools, messages: messages
        ))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AnthropicClientError.httpError(status: http.statusCode, body: body)
        }

        var tools: [Int: (id: String, name: String, json: String)] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                if let index = event["index"] as? Int,
                   let block = event["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use",
                   let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    tools[index] = (id, name, "")
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { break }
                if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                } else if deltaType == "input_json_delta",
                          let partial = delta["partial_json"] as? String,
                          var acc = tools[index] {
                    acc.json += partial
                    tools[index] = acc
                }

            case "content_block_stop":
                if let index = event["index"] as? Int, let acc = tools.removeValue(forKey: index) {
                    let input: [String: Any]
                    if acc.json.isEmpty {
                        input = [:]
                    } else if let d = acc.json.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        input = obj
                    } else {
                        input = [:]
                    }
                    continuation.yield(.toolUseComplete(id: acc.id, name: acc.name, input: input))
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let raw = delta["stop_reason"] as? String {
                    continuation.yield(.messageStop(stopReason: AnthropicStopReason(rawValue: raw) ?? .other))
                }

            case "error":
                if let err = event["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    continuation.finish(throwing: AnthropicClientError.streamError(msg))
                }

            default: break
            }
        }
    }

    private func buildBody(
        system: String, tools: [AnthropicToolSchema], messages: [AnthropicMessage]
    ) -> [String: Any] {
        var toolBlocks: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
        }
        // Cache-break the static prefix (system prompt + tool list).
        if var last = toolBlocks.popLast() {
            last["cache_control"] = ["type": "ephemeral"]
            toolBlocks.append(last)
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "stream": true,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        return body
    }
}
