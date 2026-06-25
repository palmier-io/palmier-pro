import Foundation

// Shared config + wire-format for an OpenAI-compatible chat endpoint (a local model
// server or a LiteLLM gateway). Kept fully independent of the Anthropic builder — the
// Anthropic cache_control blocks would 400 on an OpenAI-compatible endpoint.

extension Notification.Name {
    static let openAICompatGatewayChanged = Notification.Name("openAICompatGatewayChanged")
}

// MARK: - Config (global; base URL + model in UserDefaults, key in the Keychain)

enum GatewayConfig {
    static let baseURLKey = "agentGatewayBaseURL"
    static let modelKey = "agentGatewayModel"

    // Fork default — shown PRE-FILLED in Settings so the operator just adds a key and
    // saves; the gateway is inactive (and routing falls back to Anthropic/Convex) until
    // it's actually saved, so a fresh install / tests don't hit the network.
    static let defaultBaseURL = "https://api.proto-labs.ai/v1"
    static let defaultModel = "protolabs/reasoning"

    static var baseURLString: String { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "" }

    static func save(baseURL: String, model: String) {
        UserDefaults.standard.set(baseURL, forKey: baseURLKey)
        UserDefaults.standard.set(model, forKey: modelKey)
        NotificationCenter.default.post(name: .openAICompatGatewayChanged, object: nil)
    }
}

enum GatewayKeychain {
    private static let account = "openai-compat-gateway-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .openAICompatGatewayChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENAI_COMPAT_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .openAICompatGatewayChanged, object: nil)
    }
}

enum OpenAICompatError: LocalizedError {
    case missingBaseURL
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "No gateway base URL is set."
        case .httpError(let status, let body): "Gateway API error (\(status)): \(body.prefix(500))"
        case .streamError(let msg): "Stream error: \(msg)"
        }
    }
}

// MARK: - Request body builder (POST /chat/completions)

enum OpenAIRequestBody {
    static func build(
        model: String,
        maxTokens: Int,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> [String: Any] {
        var out: [[String: Any]] = []
        if !system.isEmpty {
            out.append(["role": "system", "content": system])
        }
        for msg in messages {
            out.append(contentsOf: translate(msg))
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": out,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ],
                ]
            }
            body["tool_choice"] = "auto"
        }
        return body
    }

    // One Anthropic message can fan out to several OpenAI messages: a user turn with
    // tool_result blocks becomes role:"tool" messages; an assistant turn with tool_use
    // blocks becomes one assistant message carrying tool_calls.
    private static func translate(_ msg: AnthropicMessage) -> [[String: Any]] {
        let isUser = (msg.role == .user)
        var userParts: [[String: Any]] = []
        var toolMessages: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []
        var assistantText = ""

        for block in msg.content {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                let text = block["text"] as? String ?? ""
                if isUser {
                    userParts.append(["type": "text", "text": text])
                } else {
                    assistantText += text
                }
            case "image":
                if let source = block["source"] as? [String: Any],
                   let mime = source["media_type"] as? String,
                   let data = source["data"] as? String {
                    userParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mime);base64,\(data)"],
                    ])
                }
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": jsonString(input)],
                ])
            case "tool_result":
                let toolUseId = block["tool_use_id"] as? String ?? ""
                toolMessages.append([
                    "role": "tool",
                    "tool_call_id": toolUseId,
                    "content": toolResultText(block["content"]),
                ])
            default:
                break
            }
        }

        var result: [[String: Any]] = toolMessages
        if isUser {
            if !userParts.isEmpty {
                let single = userParts.count == 1 && (userParts[0]["type"] as? String) == "text"
                let content: Any = single ? (userParts[0]["text"] as? String ?? "") : userParts
                result.append(["role": "user", "content": content])
            }
        } else if !toolCalls.isEmpty {
            var assistant: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            assistant["content"] = assistantText.isEmpty ? NSNull() : assistantText
            result.append(assistant)
        } else if !assistantText.isEmpty {
            result.append(["role": "assistant", "content": assistantText])
        }
        return result
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text": parts.append(block["text"] as? String ?? "")
            case "image": parts.append("[image]")
            default: break
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }
}

// MARK: - SSE parser (OpenAI chat-completions stream)

/// Synchronous, per-line state machine for the OpenAI chat-completions stream. Split
/// from the async transport so the index-keyed tool_call accumulation (the easiest
/// thing to get wrong) is unit-testable with canned SSE lines.
struct OpenAISSEDecoder {
    struct Step {
        var events: [AnthropicStreamEvent] = []
        var error: String?
    }

    private struct PendingTool {
        var id = ""
        var name = ""
        var args = ""
    }

    private var pending: [Int: PendingTool] = [:]
    private(set) var stopped = false

    mutating func consume(_ line: String) -> Step {
        guard line.hasPrefix("data:") else { return Step() }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return Step() }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Step() }

        if let err = event["error"] as? [String: Any], let msg = err["message"] as? String {
            return Step(error: msg)
        }
        guard let choices = event["choices"] as? [[String: Any]],
              let choice = choices.first else { return Step() }

        var events: [AnthropicStreamEvent] = []
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["content"] as? String, !text.isEmpty {
                events.append(.textDelta(text))
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                accumulate(calls)
            }
        }

        if let reason = choice["finish_reason"] as? String {
            let hadTools = reason == "tool_calls" || !pending.isEmpty
            events.append(contentsOf: flush())
            let stop: AnthropicStopReason = hadTools ? .toolUse
                : (reason == "length" ? .maxTokens : .endTurn)
            events.append(.messageStop(stopReason: stop))
            stopped = true
        }
        return Step(events: events)
    }

    /// Emit a terminal stop when the stream closed without a finish_reason.
    mutating func finish() -> [AnthropicStreamEvent] {
        if stopped { return [] }
        let hadTools = !pending.isEmpty
        var events = flush()
        events.append(.messageStop(stopReason: hadTools ? .toolUse : .endTurn))
        stopped = true
        return events
    }

    private mutating func accumulate(_ calls: [[String: Any]]) {
        for tc in calls {
            let index = tc["index"] as? Int ?? 0
            var acc = pending[index] ?? PendingTool()
            if let id = tc["id"] as? String, !id.isEmpty { acc.id = id }
            if let fn = tc["function"] as? [String: Any] {
                if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
                if let args = fn["arguments"] as? String { acc.args += args }
            }
            pending[index] = acc
        }
    }

    private mutating func flush() -> [AnthropicStreamEvent] {
        let events = pending.keys.sorted().map { index -> AnthropicStreamEvent in
            let tool = pending[index]!
            return .toolUseComplete(
                id: tool.id,
                name: tool.name,
                inputJSON: tool.args.isEmpty ? "{}" : tool.args
            )
        }
        pending.removeAll()
        return events
    }
}

enum OpenAISSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var decoder = OpenAISSEDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let step = decoder.consume(line)
            if let error = step.error {
                continuation.finish(throwing: OpenAICompatError.streamError(error))
                return
            }
            for event in step.events { continuation.yield(event) }
        }
        for event in decoder.finish() { continuation.yield(event) }
    }
}
