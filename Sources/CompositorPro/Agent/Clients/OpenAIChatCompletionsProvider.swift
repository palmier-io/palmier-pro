import Foundation

/// `/chat/completions` request body. Deliberately sends only what every OpenAI-compatible
/// server accepts: no `max_tokens` (a fixed budget overflows small local contexts), no
/// reasoning knobs, no store/response options.
enum OpenAIChatCompletionsRequestBody {
    static func build(
        modelID: String,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        reasoningEffort: AgentReasoningEffort = .none
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "stream": true,
            "messages": chatMessages(system: system, messages: messages),
        ]
        if reasoningEffort != .none {
            // Two spellings because OpenAI-compatible gateways disagree: OpenRouter normalises
            // to `reasoning.effort`, while OpenAI-style `/chat/completions` servers read the flat
            // `reasoning_effort`. Gateways that support neither ignore the field they do not
            // know, so sending both reaches whichever convention the user's endpoint follows.
            body["reasoning"] = ["effort": reasoningEffort.rawValue]
            body["reasoning_effort"] = reasoningEffort.rawValue
        }
        if !tools.isEmpty {
            body["tools"] = tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": $0.name,
                        "description": $0.description,
                        "parameters": $0.inputSchema,
                    ],
                ]
            }
        }
        return body
    }

    private static func chatMessages(
        system: String,
        messages: [AgentRequestMessage]
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pendingToolCalls = Set<String>()
        var imageResults: [ToolResult.Block] = []

        func appendImageResults() {
            guard !imageResults.isEmpty else { return }
            out.append(turn(role: "user", content: imageResults, toolCalls: []))
            imageResults.removeAll(keepingCapacity: true)
        }

        if !system.isEmpty {
            out.append(["role": "system", "content": system])
        }
        for message in messages {
            var content: [ToolResult.Block] = []
            var toolCalls: [[String: Any]] = []
            let role = message.role.rawValue

            func appendMessage() {
                guard !content.isEmpty || !toolCalls.isEmpty else { return }
                out.append(turn(role: role, content: content, toolCalls: toolCalls))
                content.removeAll(keepingCapacity: true)
                toolCalls.removeAll(keepingCapacity: true)
            }

            for block in message.content {
                switch block {
                case .image(let base64, let mediaType):
                    content.append(.image(base64: base64, mediaType: mediaType))
                case .content(let block):
                    switch block {
                    // No portable way to replay reasoning state; dropping it is correct.
                    case .thinking, .redactedThinking, .openAIReasoning:
                        continue
                    case .text(let value):
                        if !value.isEmpty { content.append(.text(value)) }
                    case .toolUse(let id, let name, let inputJSON):
                        pendingToolCalls.insert(id)
                        toolCalls.append([
                            "id": id,
                            "type": "function",
                            "function": ["name": name, "arguments": nonEmptyJSONObject(inputJSON)],
                        ])
                    case .toolResult(let toolUseID, let output, let isError):
                        appendMessage()
                        let reply: String
                        if output.contains(where: \.isImage) {
                            let label = isError ? "Tool error" : "Tool result"
                            reply = "\(label) includes images. Full content follows in a user message after this tool batch."
                            imageResults.append(.text("\(label) for tool call \(toolUseID):"))
                            imageResults.append(contentsOf: output)
                        } else {
                            reply = toolResultText(output, isError: isError)
                        }
                        out.append([
                            "role": "tool",
                            "tool_call_id": toolUseID,
                            "content": reply,
                        ])
                        pendingToolCalls.remove(toolUseID)
                        // Chat Completions tool messages are text-only; images follow the complete tool batch.
                        if pendingToolCalls.isEmpty { appendImageResults() }
                    }
                }
            }
            appendMessage()
        }
        appendImageResults()
        return out
    }

    private static func turn(
        role: String,
        content: [ToolResult.Block],
        toolCalls: [[String: Any]]
    ) -> [String: Any] {
        var message: [String: Any] = ["role": role]
        if content.contains(where: \.isImage) {
            message["content"] = content.map { block -> [String: Any] in
                switch block {
                case .text(let text):
                    ["type": "text", "text": text]
                case .image(let base64, let mediaType):
                    ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(base64)"]]
                }
            }
        } else {
            message["content"] = content.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined()
        }
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        return message
    }

    /// Servers reject an empty arguments string, and the agent's own history uses "{}" for
    /// a no-argument call, so a parse failure degrades to an empty object rather than bad JSON.
    private static func nonEmptyJSONObject(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: normalized, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func toolResultText(_ output: [ToolResult.Block], isError: Bool) -> String {
        let text = output.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined(separator: "\n")
        if isError { return text.isEmpty ? "Tool error" : "Tool error: \(text)" }
        return text
    }
}

enum OpenAIChatCompletionsSSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var parser = OpenAIChatCompletionsStreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try parser.consume(line: line) {
                continuation.yield(event)
            }
            if parser.didTerminate { break }
        }
        try parser.finish()
    }
}

struct OpenAIChatCompletionsStreamParser {
    private struct PendingToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var pending: [Int: PendingToolCall] = [:]
    private(set) var didTerminate = false

    mutating func consume(line: String) throws -> [AgentStreamEvent] {
        guard !didTerminate, line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else {
            return finishEvents()
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let error = object["error"] as? [String: Any] {
            throw AgentClientTransportError.streamError(
                provider: .custom,
                message: error["message"] as? String ?? "Unknown stream error."
            )
        }
        return try consume(chunk: object)
    }

    mutating func consume(chunk: [String: Any]) throws -> [AgentStreamEvent] {
        guard !didTerminate,
              let choices = chunk["choices"] as? [[String: Any]],
              let choice = choices.first
        else { return [] }

        var events: [AgentStreamEvent] = []
        if let delta = choice["delta"] as? [String: Any] {
            // Gateways spell reasoning three ways, and reading only one leaves the panel showing
            // anonymous activity dots for the whole time a reasoning model thinks. OpenRouter
            // streams `reasoning`, or `reasoning_details` when the model returns structured
            // blocks; `reasoning_content` is the DeepSeek spelling. Prefer the plain string and
            // fall back to the details so a gateway that sends both is not rendered twice.
            if let reasoning = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String),
               !reasoning.isEmpty {
                events.append(.reasoningSummaryDelta(reasoning))
            } else {
                for detail in delta["reasoning_details"] as? [[String: Any]] ?? [] {
                    if let text = detail["text"] as? String, !text.isEmpty {
                        events.append(.reasoningSummaryDelta(text))
                    }
                }
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.textDelta(content))
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                accumulate(call)
            }
        }
        if let reason = choice["finish_reason"] as? String {
            events.append(contentsOf: finishEvents(finishReason: reason))
        }
        return events
    }

    private mutating func accumulate(_ call: [String: Any]) {
        // Servers key streamed calls by `index`; fall back to arrival order for those that don't.
        let slot = (call["index"] as? Int) ?? pending.count
        var entry = pending[slot] ?? PendingToolCall()
        if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
        if let function = call["function"] as? [String: Any] {
            if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
            if let arguments = function["arguments"] as? String { entry.arguments += arguments }
        }
        pending[slot] = entry
    }

    private mutating func finishEvents(finishReason: String? = nil) -> [AgentStreamEvent] {
        // Providers repeat `finish_reason` on a trailing usage-only chunk, and `[DONE]` adds a
        // third pass with no reason. Re-terminating would emit a second stop reason and lose
        // the one that matters, so only the first terminal chunk counts.
        guard !didTerminate else { return [] }
        didTerminate = true
        var events: [AgentStreamEvent] = []
        var hasToolCall = false
        for (_, call) in pending.sorted(by: { $0.key < $1.key }) where !call.name.isEmpty {
            events.append(.toolUseComplete(
                id: call.id.isEmpty ? "call_\(UUID().uuidString)" : call.id,
                name: call.name,
                inputJSON: call.arguments.isEmpty ? "{}" : call.arguments
            ))
            hasToolCall = true
        }
        pending.removeAll()
        // A gateway may close with a generic reason while the deltas still carried calls, and
        // `[DONE]` arrives with no reason at all. The accumulated calls are the ground truth.
        events.append(.messageStop(stopReason: stopReason(for: finishReason, hasToolCall: hasToolCall)))
        return events
    }

    private func stopReason(for raw: String?, hasToolCall: Bool) -> AgentStopReason {
        switch raw {
        case "tool_calls", "function_call": .toolUse
        case "length": .maxTokens
        case "content_filter": .refusal
        default: hasToolCall ? .toolUse : .endTurn
        }
    }

    func finish() throws {
        guard didTerminate else {
            throw AgentClientTransportError.streamError(
                provider: .custom,
                message: "The stream ended before a terminal event."
            )
        }
    }
}
