import Foundation

// MARK: - Shared value types

enum AnthropicModel: String, CaseIterable, Sendable {
    case sonnet5 = "claude-sonnet-5"
    case opus48 = "claude-opus-4-8"
    case haiku45 = "claude-haiku-4-5-20251001"

    var displayName: String {
        switch self {
        case .sonnet5: "Sonnet 5"
        case .opus48: "Opus 4.8"
        case .haiku45: "Haiku 4.5"
        }
    }

    var requestExtras: [String: Any] {
        switch self {
        case .sonnet5: ["output_config": ["effort": "low"]]
        default: [:]
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

enum AnthropicStreamEvent: Sendable {
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
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

// MARK: - Client protocol

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
}

// MARK: - Usage logging

enum AgentUsageLog {
    static func record(_ usage: [String: Any]) {
        #if DEBUG
        let input = usage["input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let billed = input + cacheWrite + cacheRead
        let readPct = billed > 0 ? Int((Double(cacheRead) / Double(billed)) * 100) : 0
        print("[agent cache] input=\(input) cacheWrite=\(cacheWrite) cacheRead=\(cacheRead) (\(readPct)% read)")
        #endif
    }
}

// MARK: - Shared SSE parser

enum AnthropicSSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var pendingTools: [Int: (id: String, name: String, json: String)] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    AgentUsageLog.record(usage)
                }

            case "content_block_start":
                if let index = event["index"] as? Int,
                   let block = event["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use",
                   let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    pendingTools[index] = (id, name, "")
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { break }
                if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                } else if deltaType == "input_json_delta",
                          let partial = delta["partial_json"] as? String,
                          var acc = pendingTools[index] {
                    acc.json += partial
                    pendingTools[index] = acc
                }

            case "content_block_stop":
                if let index = event["index"] as? Int, let acc = pendingTools.removeValue(forKey: index) {
                    let json = acc.json.isEmpty ? "{}" : acc.json
                    continuation.yield(.toolUseComplete(id: acc.id, name: acc.name, inputJSON: json))
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
}

// MARK: - Request body builder

enum AnthropicRequestBody {
    static func build(
        model: AnthropicModel,
        maxTokens: Int,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> [String: Any] {
        var toolBlocks: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
        }
        // Prompt-cache boundary covers system + tools.
        if var last = toolBlocks.popLast() {
            last["cache_control"] = ["type": "ephemeral"]
            toolBlocks.append(last)
        }
        // Prompt-cache the conversation prefix
        var messageBlocks: [[String: Any]] = messages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        if var lastMsg = messageBlocks.popLast(),
           var content = lastMsg["content"] as? [[String: Any]],
           var lastBlock = content.popLast() {
            lastBlock["cache_control"] = ["type": "ephemeral"]
            content.append(lastBlock)
            lastMsg["content"] = content
            messageBlocks.append(lastMsg)
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "stream": true,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messageBlocks,
        ]
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        for (key, value) in model.requestExtras { body[key] = value }
        return body
    }
}
