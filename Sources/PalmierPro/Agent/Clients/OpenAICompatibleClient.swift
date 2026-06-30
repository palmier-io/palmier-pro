import Foundation

extension Notification.Name {
    static let openAICompatibleSettingsChanged = Notification.Name("openAICompatibleSettingsChanged")
}

struct OpenAICompatibleSettings: Equatable, Sendable {
    static let baseURLDefaultsKey = "openAICompatibleBaseURL"
    static let modelDefaultsKey = "openAICompatibleModel"

    let baseURL: String
    let endpoint: URL
    let model: String
    let apiKey: String

    var hasAPIKey: Bool { !apiKey.isEmpty }

    static func load() -> OpenAICompatibleSettings? {
        let base = configuredBaseURL
        let model = configuredModel
        guard let endpoint = OpenAICompatibleEndpoint.normalizedURL(from: base),
              !model.isEmpty else { return nil }
        return OpenAICompatibleSettings(
            baseURL: base,
            endpoint: endpoint,
            model: model,
            apiKey: OpenAICompatibleKeychain.load() ?? ""
        )
    }

    static var savedBaseURLString: String {
        UserDefaults.standard.string(forKey: baseURLDefaultsKey) ?? ""
    }

    static var savedModel: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
    }

    static func save(baseURL: String, model: String) {
        UserDefaults.standard.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLDefaultsKey)
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .openAICompatibleSettingsChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: baseURLDefaultsKey)
        UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        OpenAICompatibleKeychain.delete()
        NotificationCenter.default.post(name: .openAICompatibleSettingsChanged, object: nil)
    }

    private static var configuredBaseURL: String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENAI_COMPATIBLE_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return savedBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var configuredModel: String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENAI_COMPATIBLE_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return savedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OpenAICompatibleEndpoint {
    static func normalizedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil else { return nil }

        var pathParts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if pathParts.suffix(2) == ["chat", "completions"] {
            return components.url
        }

        if pathParts.last == "v1" {
            pathParts.append(contentsOf: ["chat", "completions"])
        } else {
            pathParts.append(contentsOf: ["v1", "chat", "completions"])
        }
        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }
}

enum OpenAICompatibleKeychain {
    private static let account = "openai-compatible-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .openAICompatibleSettingsChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENAI_COMPATIBLE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .openAICompatibleSettingsChanged, object: nil)
    }
}

enum OpenAICompatibleClientError: LocalizedError {
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let body): "OpenAI-compatible API error (\(status)): \(body.prefix(500))"
        case .streamError(let msg): "OpenAI-compatible stream error: \(msg)"
        }
    }
}

struct OpenAICompatibleClient: AgentClient {
    let settings: OpenAICompatibleSettings
    var maxTokens: Int = 8192

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
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
        tools: [AgentToolSchema],
        messages: [AgentClientMessage],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: settings.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: OpenAICompatibleRequestBody.build(
                model: settings.model,
                maxTokens: maxTokens,
                system: system,
                tools: tools,
                messages: messages
            ),
            options: [.sortedKeys]
        )
        AgentDebugLog.trace("openai request host=\(settings.endpoint.host ?? "-") model=\(settings.model) messages=\(messages.count) tools=\(tools.count)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            AgentDebugLog.trace("openai http error status=\(http.statusCode) bodyBytes=\(body.utf8.count)")
            throw OpenAICompatibleClientError.httpError(status: http.statusCode, body: body)
        }

        try await OpenAICompatibleSSE.parse(bytes: bytes, continuation: continuation)
    }
}

enum OpenAICompatibleRequestBody {
    static func build(
        model: String,
        maxTokens: Int,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": openAIMessages(system: system, messages: messages),
        ]
        let toolBlocks = tools.map {
            [
                "type": "function",
                "function": [
                    "name": $0.name,
                    "description": $0.description,
                    "parameters": $0.inputSchema,
                ],
            ]
        }
        if !toolBlocks.isEmpty {
            body["tools"] = toolBlocks
            body["tool_choice"] = "auto"
        }
        return body
    }

    private static func openAIMessages(system: String, messages: [AgentClientMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = [
            ["role": "system", "content": system],
        ]

        for message in messages {
            switch message.role {
            case .user:
                result.append(contentsOf: userMessages(from: message.content))
            case .assistant:
                result.append(assistantMessage(from: message.content))
            }
        }

        return result
    }

    private static func userMessages(from blocks: [[String: Any]]) -> [[String: Any]] {
        var contentParts: [[String: Any]] = []
        var toolMessages: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    contentParts.append(["type": "text", "text": text])
                }
            case "image":
                if let image = imageURLPart(from: block) {
                    contentParts.append(image)
                }
            case "tool_result":
                if let toolMessage = toolResultMessage(from: block) {
                    toolMessages.append(toolMessage)
                }
            default:
                break
            }
        }

        var messages: [[String: Any]] = []
        if !contentParts.isEmpty {
            messages.append(["role": "user", "content": compactContent(contentParts)])
        }
        messages.append(contentsOf: toolMessages)
        return messages
    }

    private static func assistantMessage(from blocks: [[String: Any]]) -> [String: Any] {
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            case "tool_use":
                if let toolCall = toolCall(from: block) {
                    toolCalls.append(toolCall)
                }
            default:
                break
            }
        }

        var message: [String: Any] = ["role": "assistant"]
        let content = textParts.joined()
        if !content.isEmpty {
            message["content"] = content
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }
        if message["content"] == nil && toolCalls.isEmpty {
            message["content"] = ""
        }
        return message
    }

    private static func imageURLPart(from block: [String: Any]) -> [String: Any]? {
        guard let source = block["source"] as? [String: Any],
              source["type"] as? String == "base64",
              let mediaType = source["media_type"] as? String,
              let data = source["data"] as? String,
              !mediaType.isEmpty,
              !data.isEmpty else { return nil }
        return [
            "type": "image_url",
            "image_url": ["url": "data:\(mediaType);base64,\(data)"],
        ]
    }

    private static func toolResultMessage(from block: [String: Any]) -> [String: Any]? {
        guard let id = block["tool_use_id"] as? String, !id.isEmpty else { return nil }
        let contentBlocks = block["content"] as? [[String: Any]] ?? []
        let content = contentBlocks.compactMap(toolResultText).joined(separator: "\n")
        let isError = block["is_error"] as? Bool ?? false
        return [
            "role": "tool",
            "tool_call_id": id,
            "content": isError ? "Error: \(content)" : content,
        ]
    }

    private static func toolResultText(from block: [String: Any]) -> String? {
        guard let type = block["type"] as? String else { return nil }
        switch type {
        case "text":
            return block["text"] as? String
        case "image":
            if let source = block["source"] as? [String: Any],
               let mediaType = source["media_type"] as? String {
                return "[Image result: \(mediaType)]"
            }
            return "[Image result]"
        default:
            return nil
        }
    }

    private static func toolCall(from block: [String: Any]) -> [String: Any]? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String,
              !id.isEmpty,
              !name.isEmpty else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        return [
            "id": id,
            "type": "function",
            "function": [
                "name": name,
                "arguments": jsonString(input),
            ],
        ]
    }

    private static func compactContent(_ parts: [[String: Any]]) -> Any {
        if parts.count == 1,
           let first = parts.first,
           first["type"] as? String == "text",
           let text = first["text"] as? String {
            return text
        }
        return parts
    }

    private static func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

enum OpenAICompatibleSSE {
    struct PendingToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var pendingTools: [Int: PendingToolCall] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events = try events(fromDataLine: line, pendingTools: &pendingTools)
            for event in events {
                continuation.yield(event)
            }
        }
        AgentDebugLog.trace("openai sse eof pending=\(pendingTools.count)")
        for event in finishStream(pendingTools: &pendingTools) {
            continuation.yield(event)
        }
    }

    static func events(fromDataLine line: String, pendingTools: inout [Int: PendingToolCall]) throws -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else {
            AgentDebugLog.trace("openai sse done pending=\(pendingTools.count)")
            return finishStream(pendingTools: &pendingTools)
        }
        guard let data = payload.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if let error = event["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Unknown stream error"
            throw OpenAICompatibleClientError.streamError(message)
        }

        guard let choices = event["choices"] as? [[String: Any]] else { return [] }
        var out: [AgentStreamEvent] = []
        for choice in choices {
            if let delta = choice["delta"] as? [String: Any] {
                appendDeltaEvents(delta, pendingTools: &pendingTools, output: &out)
            }
            if let finishReason = choice["finish_reason"] as? String {
                AgentDebugLog.trace("openai sse finish reason=\(finishReason) pending=\(pendingTools.count)")
                appendFinishEvents(finishReason, pendingTools: &pendingTools, output: &out)
            }
        }
        return out
    }

    static func finishStream(pendingTools: inout [Int: PendingToolCall]) -> [AgentStreamEvent] {
        var out: [AgentStreamEvent] = []
        if flushPendingToolEvents(pendingTools: &pendingTools, output: &out) {
            AgentDebugLog.trace("openai sse finishStream flushedTools=\(out.count)")
            out.append(.messageStop(stopReason: .toolUse))
        }
        return out
    }

    private static func appendDeltaEvents(
        _ delta: [String: Any],
        pendingTools: inout [Int: PendingToolCall],
        output: inout [AgentStreamEvent]
    ) {
        if let content = delta["content"] as? String, !content.isEmpty {
            output.append(.textDelta(content))
        }

        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let index = call["index"] as? Int ?? 0
                var pending = pendingTools[index] ?? PendingToolCall(id: "", name: "", arguments: "")
                if let id = call["id"] as? String, !id.isEmpty { pending.id = id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty {
                        if pending.name != name {
                            AgentDebugLog.trace("openai sse tool_delta start index=\(index) name=\(name)")
                        }
                        pending.name = name
                    }
                    if let arguments = function["arguments"] as? String { pending.arguments += arguments }
                }
                pendingTools[index] = pending
            }
        }

        if let function = delta["function_call"] as? [String: Any] {
            var pending = pendingTools[0] ?? PendingToolCall(id: "", name: "", arguments: "")
            if let name = function["name"] as? String, !name.isEmpty {
                if pending.name != name {
                    AgentDebugLog.trace("openai sse function_delta start name=\(name)")
                }
                pending.name = name
            }
            if let arguments = function["arguments"] as? String { pending.arguments += arguments }
            pendingTools[0] = pending
        }
    }

    private static func appendFinishEvents(
        _ finishReason: String,
        pendingTools: inout [Int: PendingToolCall],
        output: inout [AgentStreamEvent]
    ) {
        if isToolFinishReason(finishReason) || shouldFlushPendingTools(for: finishReason, pendingTools: pendingTools) {
            let emittedTool = flushPendingToolEvents(pendingTools: &pendingTools, output: &output)
            output.append(.messageStop(stopReason: emittedTool ? .toolUse : stopReason(from: finishReason)))
        } else {
            output.append(.messageStop(stopReason: stopReason(from: finishReason)))
        }
    }

    private static func isToolFinishReason(_ finishReason: String) -> Bool {
        switch finishReason {
        case "tool_calls", "function_call", "tool_call", "tool_use", "tools":
            true
        default:
            false
        }
    }

    private static func shouldFlushPendingTools(for finishReason: String, pendingTools: [Int: PendingToolCall]) -> Bool {
        finishReason == "stop" && pendingTools.values.contains { !$0.name.isEmpty }
    }

    private static func flushPendingToolEvents(
        pendingTools: inout [Int: PendingToolCall],
        output: inout [AgentStreamEvent]
    ) -> Bool {
        var emittedTool = false
        for index in pendingTools.keys.sorted() {
            guard let pending = pendingTools[index], !pending.name.isEmpty else { continue }
            output.append(.toolUseComplete(
                id: pending.id.isEmpty ? "call_\(index)" : pending.id,
                name: pending.name,
                inputJSON: pending.arguments.isEmpty ? "{}" : pending.arguments
            ))
            AgentDebugLog.trace("openai sse flush tool name=\(pending.name) id=\(pending.id.isEmpty ? "call_\(index)" : pending.id) argBytes=\(pending.arguments.utf8.count)")
            emittedTool = true
        }
        pendingTools.removeAll()
        return emittedTool
    }

    private static func stopReason(from finishReason: String) -> AgentStopReason {
        switch finishReason {
        case "stop": .endTurn
        case "length": .maxTokens
        case "content_filter": .refusal
        default: .other
        }
    }
}
