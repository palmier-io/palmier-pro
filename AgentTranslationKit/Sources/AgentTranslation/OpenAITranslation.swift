import Foundation

// MARK: - Portable value types

public enum AgentStopReason: String, Sendable, Equatable {
    case endTurn, toolUse, maxTokens, refusal, other
}

public enum AgentStreamEvent: Sendable, Equatable {
    case text(String)
    case toolCall(id: String, name: String, argumentsJSON: String)
    case stop(AgentStopReason)
}

public struct AgentToolSchema {
    public let name: String
    public let description: String
    public let parameters: [String: Any]
    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AgentTurn {
    public enum Role: String { case user, assistant }
    public let role: Role
    /// Anthropic-style content blocks (`type`: text / image / tool_use / tool_result).
    public let content: [[String: Any]]
    public init(role: Role, content: [[String: Any]]) {
        self.role = role
        self.content = content
    }
}

public enum OpenAITranslationError: Error, Equatable {
    case stream(String)
}

// MARK: - Request building (Anthropic-shaped -> OpenAI Chat Completions)

public enum OpenAIRequestBuilder {
    public static func body(
        model: String,
        maxTokens: Int,
        temperature: Double?,
        enablePromptCache: Bool,
        system: String,
        tools: [AgentToolSchema],
        turns: [AgentTurn]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": openAIMessages(system: system, enablePromptCache: enablePromptCache, turns: turns),
            "stream": true,
            "max_tokens": maxTokens,
            "stream_options": ["include_usage": true],
        ]
        if let temperature { body["temperature"] = temperature }
        let toolBlocks = openAITools(tools)
        if !toolBlocks.isEmpty {
            body["tools"] = toolBlocks
            body["tool_choice"] = "auto"
        }
        return body
    }

    public static func openAITools(_ tools: [AgentToolSchema]) -> [[String: Any]] {
        tools.map { tool in
            ["type": "function", "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters,
            ]] as [String: Any]
        }
    }

    public static func openAIMessages(
        system: String,
        enablePromptCache: Bool,
        turns: [AgentTurn]
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = [systemMessage(system, cache: enablePromptCache)]
        for turn in turns {
            switch turn.role {
            case .assistant: messages.append(convertAssistant(turn.content))
            case .user: messages.append(contentsOf: convertUser(turn.content))
            }
        }
        return messages
    }

    static func systemMessage(_ system: String, cache: Bool) -> [String: Any] {
        guard cache else { return ["role": "system", "content": system] }
        // Cache breakpoint on the large static prefix; gateways with implicit
        // caching (e.g. Gemini) ignore it, gateways with manual caching use it.
        return ["role": "system", "content": [
            ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]
        ]]
    }

    static func convertAssistant(_ content: [[String: Any]]) -> [String: Any] {
        var text = ""
        var toolCalls: [[String: Any]] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { text += t }
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": jsonString(block["input"])],
                ])
            default: break
            }
        }
        var message: [String: Any] = ["role": "assistant"]
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        // An assistant turn must carry content or tool_calls; never both empty.
        if !text.isEmpty { message["content"] = text }
        else if toolCalls.isEmpty { message["content"] = "" }
        return message
    }

    /// A single user turn may carry tool results (-> `tool` role messages) and/or
    /// normal text/image parts (-> a `user` message). Tool-result images cannot ride
    /// the `tool` role, so they are re-emitted as a following `user` image message.
    static func convertUser(_ content: [[String: Any]]) -> [[String: Any]] {
        var toolMessages: [[String: Any]] = []
        var deferredImages: [[String: Any]] = []
        var userParts: [[String: Any]] = []

        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, !t.isEmpty {
                    userParts.append(["type": "text", "text": t])
                }
            case "image":
                if let part = imagePart(from: block) { userParts.append(part) }
            case "tool_result":
                let id = block["tool_use_id"] as? String ?? ""
                let isError = block["is_error"] as? Bool ?? false
                let (text, images) = splitToolResult(block["content"])
                var contentText = isError ? "ERROR: " + text : text
                if contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contentText = images.isEmpty ? "(no content)" : "(image content in the following message)"
                }
                toolMessages.append(["role": "tool", "tool_call_id": id, "content": contentText])
                deferredImages.append(contentsOf: images)
            default: break
            }
        }

        var result = toolMessages
        if !deferredImages.isEmpty {
            var parts: [[String: Any]] = [["type": "text", "text": "Images returned by the preceding tool call(s):"]]
            parts.append(contentsOf: deferredImages)
            result.append(["role": "user", "content": parts])
        }
        if !userParts.isEmpty {
            result.append(["role": "user", "content": userParts])
        }
        return result
    }

    static func imagePart(from block: [String: Any]) -> [String: Any]? {
        guard let source = block["source"] as? [String: Any],
              let mime = source["media_type"] as? String,
              let data = source["data"] as? String else { return nil }
        return ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(data)"]]
    }

    static func splitToolResult(_ content: Any?) -> (text: String, images: [[String: Any]]) {
        var texts: [String] = []
        var images: [[String: Any]] = []
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text": if let t = block["text"] as? String { texts.append(t) }
                case "image": if let part = imagePart(from: block) { images.append(part) }
                default: break
                }
            }
        } else if let s = content as? String {
            texts.append(s)
        }
        return (texts.joined(separator: "\n"), images)
    }

    static func jsonString(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

// MARK: - SSE decode (OpenAI streaming -> agent events)

/// Stateful, line-at-a-time decoder for an OpenAI-style SSE stream. Kept free of
/// `URLSession.AsyncBytes` so it is testable on any platform: feed it raw `data:`
/// lines and collect the events. Tool-call argument fragments are accumulated by
/// their choice index until the terminating `finish_reason`.
public struct OpenAISSEDecoder {
    private var pending: [Int: (id: String, name: String, args: String)] = [:]

    public init() {}

    public mutating func consume(line: String) throws -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [] }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        if let err = event["error"] as? [String: Any] {
            throw OpenAITranslationError.stream(err["message"] as? String ?? "Unknown stream error")
        }
        guard let choice = (event["choices"] as? [[String: Any]])?.first else { return [] }

        var events: [AgentStreamEvent] = []
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["content"] as? String, !text.isEmpty {
                events.append(.text(text))
            } else if let parts = delta["content"] as? [[String: Any]] {
                for part in parts where part["type"] as? String == "text" {
                    if let text = part["text"] as? String, !text.isEmpty { events.append(.text(text)) }
                }
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    let index = call["index"] as? Int ?? 0
                    var acc = pending[index] ?? (id: "", name: "", args: "")
                    if let id = call["id"] as? String, !id.isEmpty { acc.id = id }
                    if let fn = call["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
                        if let args = fn["arguments"] as? String { acc.args += args }
                    }
                    pending[index] = acc
                }
            }
        }

        if let reason = choice["finish_reason"] as? String {
            for index in pending.keys.sorted() {
                let acc = pending[index]!
                events.append(.toolCall(
                    id: acc.id.isEmpty ? "call_\(index)" : acc.id,
                    name: acc.name,
                    argumentsJSON: acc.args.isEmpty ? "{}" : acc.args
                ))
            }
            pending.removeAll()
            events.append(.stop(Self.stopReason(reason)))
        }
        return events
    }

    public static func stopReason(_ raw: String) -> AgentStopReason {
        switch raw {
        case "tool_calls", "function_call": return .toolUse
        case "stop", "end_turn": return .endTurn
        case "length", "max_tokens": return .maxTokens
        case "content_filter": return .refusal
        default: return .other
        }
    }
}
