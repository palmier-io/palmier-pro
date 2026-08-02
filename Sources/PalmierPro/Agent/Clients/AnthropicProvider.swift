import Foundation

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
                   let blockType = block["type"] as? String {
                    if blockType == "tool_use",
                       let id = block["id"] as? String,
                       let name = block["name"] as? String {
                        pendingTools[index] = (id, name, "")
                    } else if blockType == "redacted_thinking",
                              let data = block["data"] as? String {
                        continuation.yield(.redactedThinking(data))
                    }
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { break }
                if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                } else if deltaType == "thinking_delta",
                          let thinking = delta["thinking"] as? String,
                          !thinking.isEmpty {
                    continuation.yield(.thinkingDelta(thinking))
                } else if deltaType == "signature_delta",
                          let signature = delta["signature"] as? String,
                          !signature.isEmpty {
                    continuation.yield(.thinkingSignature(signature))
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
                    throw AgentClientTransportError.streamError(provider: .anthropic, message: msg)
                }

            default: break
            }
        }
    }
}

enum AnthropicRequestBody {
    static func build(
        model: AgentModel,
        reasoningEffort: AgentReasoningEffort = .medium,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> [String: Any] {
        precondition(model.provider == .anthropic)
        precondition(model.supportedReasoningEfforts.contains(reasoningEffort))
        var toolBlocks: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
        }
        // Prompt-cache boundary covers system + tools.
        if var last = toolBlocks.popLast() {
            last["cache_control"] = ["type": "ephemeral"]
            toolBlocks.append(last)
        }
        // Prompt-cache the conversation prefix
        var messageBlocks: [[String: Any]] = messages.compactMap { message in
            let content = message.content.compactMap(contentJSON)
            return content.isEmpty ? nil : ["role": message.role.rawValue, "content": content]
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
            "max_tokens": model.maxOutputTokens,
            "stream": true,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messageBlocks,
            "output_config": ["effort": reasoningEffort.rawValue],
            "thinking": ["type": "adaptive", "display": "summarized"],
        ]
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        return body
    }

    private static func contentJSON(_ block: AgentRequestBlock) -> [String: Any]? {
        switch block {
        case .image(let base64, let mediaType):
            return imageJSON(base64: base64, mediaType: mediaType)
        case .content(let content):
            switch content {
            case .thinking(let text, let signature):
                guard !signature.isEmpty else { return nil }
                return ["type": "thinking", "thinking": text, "signature": signature]
            case .redactedThinking(let data):
                guard !data.isEmpty else { return nil }
                return ["type": "redacted_thinking", "data": data]
            case .openAIReasoning:
                return nil
            case .text(let text):
                guard !text.isEmpty else { return nil }
                return ["type": "text", "text": text]
            case .toolUse(let id, let name, let inputJSON):
                return [
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": parseJSONObject(inputJSON),
                ]
            case .toolResult(let toolUseID, let content, let isError):
                return [
                    "type": "tool_result",
                    "tool_use_id": toolUseID,
                    "content": content.map(toolResultJSON),
                    "is_error": isError,
                ]
            }
        }
    }

    private static func toolResultJSON(_ block: ToolResult.Block) -> [String: Any] {
        switch block {
        case .text(let text):
            ["type": "text", "text": text]
        case .image(let base64, let mediaType):
            imageJSON(base64: base64, mediaType: mediaType)
        }
    }

    private static func imageJSON(base64: String, mediaType: String) -> [String: Any] {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": mediaType, "data": base64],
        ]
    }

    private static func parseJSONObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
