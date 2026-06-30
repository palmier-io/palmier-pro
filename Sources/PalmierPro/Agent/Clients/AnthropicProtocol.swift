import Foundation

enum AnthropicModel: String, CaseIterable, Sendable {
    case sonnet46 = "claude-sonnet-4-6"
    case opus48 = "claude-opus-4-8"
    case haiku45 = "claude-haiku-4-5-20251001"

    var displayName: String {
        switch self {
        case .sonnet46: "Sonnet 4.6"
        case .opus48: "Opus 4.8"
        case .haiku45: "Haiku 4.5"
        }
    }
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

enum AnthropicSSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
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
                    continuation.yield(.messageStop(stopReason: AgentStopReason(rawValue: raw) ?? .other))
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

enum AnthropicRequestBody {
    static func build(
        model: AnthropicModel,
        maxTokens: Int,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> [String: Any] {
        var toolBlocks: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
        }
        if var last = toolBlocks.popLast() {
            last["cache_control"] = ["type": "ephemeral"]
            toolBlocks.append(last)
        }
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
        return body
    }
}
