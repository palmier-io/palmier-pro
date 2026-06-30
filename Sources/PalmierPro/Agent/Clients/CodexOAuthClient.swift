import Foundation

struct CodexOAuthClient: AgentClient {
    let model: String

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let accessToken = try await CodexOAuthStore.accessToken(refreshIfNeeded: true)
                    let accountID = CodexOAuthStore.accountID()
                    try await CodexResponsesClient(
                        model: model,
                        accessToken: accessToken,
                        accountID: accountID
                    )
                    .run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum CodexResponsesClientError: LocalizedError {
    case invalidEndpoint
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Codex OAuth Responses endpoint is invalid."
        case .httpError(let status, let body): "Codex OAuth Responses API error (\(status)): \(body.prefix(500))"
        case .streamError(let message): "Codex OAuth Responses stream error: \(message)"
        }
    }
}

struct CodexResponsesClient {
    var endpoint: URL = CodexOAuthAgentSettings.responsesEndpoint
    let model: String
    let accessToken: String
    let accountID: String?
    var session: URLSession = .shared

    func run(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        let request = try makeRequest(system: system, tools: tools, messages: messages)

        AgentDebugLog.trace("codex responses request host=\(endpoint.host ?? "-") model=\(model) messages=\(messages.count) tools=\(tools.count)")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            AgentDebugLog.trace("codex responses http error status=\(http.statusCode) bodyBytes=\(body.utf8.count)")
            throw CodexResponsesClientError.httpError(status: http.statusCode, body: body)
        }

        try await CodexResponsesSSE.parse(bytes: bytes, continuation: continuation)
    }

    func makeRequest(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: CodexResponsesRequestBody.build(
                model: model,
                system: system,
                tools: tools,
                messages: messages
            ),
            options: [.sortedKeys]
        )
        return request
    }
}

enum CodexResponsesRequestBody {
    static func build(
        model: String,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": responseItems(from: messages),
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "stream": true,
            "store": false,
            "include": [],
        ]

        let toolBlocks = tools.map {
            [
                "type": "function",
                "name": $0.name,
                "description": $0.description,
                "strict": false,
                "parameters": $0.inputSchema,
            ]
        }
        if !toolBlocks.isEmpty {
            body["tools"] = toolBlocks
        }
        return body
    }

    private static func responseItems(from messages: [AgentClientMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .user:
                result.append(contentsOf: userItems(from: message.content))
            case .assistant:
                result.append(contentsOf: assistantItems(from: message.content))
            }
        }
        return result
    }

    private static func userItems(from blocks: [[String: Any]]) -> [[String: Any]] {
        var content: [[String: Any]] = []
        var toolOutputs: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    content.append(["type": "input_text", "text": text])
                }
            case "image":
                if let image = imagePart(from: block) {
                    content.append(image)
                }
            case "tool_result":
                if let output = toolOutputItem(from: block) {
                    toolOutputs.append(output)
                }
            default:
                break
            }
        }

        var items: [[String: Any]] = []
        if !content.isEmpty {
            items.append(["type": "message", "role": "user", "content": content])
        }
        items.append(contentsOf: toolOutputs)
        return items
    }

    private static func assistantItems(from blocks: [[String: Any]]) -> [[String: Any]] {
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
                if let toolCall = toolCallItem(from: block) {
                    toolCalls.append(toolCall)
                }
            default:
                break
            }
        }

        var items: [[String: Any]] = []
        let text = textParts.joined()
        if !text.isEmpty {
            items.append([
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": text]],
            ])
        }
        items.append(contentsOf: toolCalls)
        return items
    }

    private static func imagePart(from block: [String: Any]) -> [String: Any]? {
        guard let source = block["source"] as? [String: Any],
              source["type"] as? String == "base64",
              let mediaType = source["media_type"] as? String,
              let data = source["data"] as? String,
              !mediaType.isEmpty,
              !data.isEmpty else { return nil }
        return [
            "type": "input_image",
            "image_url": "data:\(mediaType);base64,\(data)",
        ]
    }

    private static func toolCallItem(from block: [String: Any]) -> [String: Any]? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String,
              !id.isEmpty,
              !name.isEmpty else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        return [
            "type": "function_call",
            "call_id": id,
            "name": name,
            "arguments": jsonString(input),
        ]
    }

    private static func toolOutputItem(from block: [String: Any]) -> [String: Any]? {
        guard let id = block["tool_use_id"] as? String, !id.isEmpty else { return nil }
        let contentBlocks = block["content"] as? [[String: Any]] ?? []
        let content = contentBlocks.compactMap(toolResultText).joined(separator: "\n")
        let isError = block["is_error"] as? Bool ?? false
        return [
            "type": "function_call_output",
            "call_id": id,
            "output": isError ? "Error: \(content)" : content,
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

    private static func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

enum CodexResponsesSSE {
    struct PendingToolCall {
        var itemID: String
        var callID: String
        var name: String
        var arguments: String
    }

    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var pendingTools: [String: PendingToolCall] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events = try events(fromLine: line, pendingTools: &pendingTools)
            for event in events {
                continuation.yield(event)
            }
        }
        AgentDebugLog.trace("codex responses sse eof pending=\(pendingTools.count)")
        for event in finishStream(pendingTools: &pendingTools) {
            continuation.yield(event)
        }
    }

    static func events(fromLine line: String, pendingTools: inout [String: PendingToolCall]) throws -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return finishStream(pendingTools: &pendingTools) }
        guard let data = payload.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return [] }

        if let error = event["error"] as? [String: Any] {
            throw CodexResponsesClientError.streamError(errorMessage(error))
        }

        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                return [.textDelta(delta)]
            }
        case "response.output_item.added":
            if let item = event["item"] as? [String: Any] {
                recordPendingTool(from: item, pendingTools: &pendingTools)
            }
        case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
            appendToolArgumentDelta(from: event, pendingTools: &pendingTools)
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any] {
                return outputItemDoneEvents(from: item, pendingTools: &pendingTools)
            }
        case "response.completed":
            let toolEvents = finishStream(pendingTools: &pendingTools)
            return toolEvents.isEmpty ? [.messageStop(stopReason: .endTurn)] : toolEvents
        case "response.incomplete":
            throw CodexResponsesClientError.streamError("Response incomplete.")
        case "response.failed":
            throw CodexResponsesClientError.streamError(failedResponseMessage(event))
        default:
            break
        }
        return []
    }

    static func finishStream(pendingTools: inout [String: PendingToolCall]) -> [AgentStreamEvent] {
        let events = flushPendingTools(pendingTools: &pendingTools)
        guard !events.isEmpty else { return [] }
        return events + [.messageStop(stopReason: .toolUse)]
    }

    private static func outputItemDoneEvents(
        from item: [String: Any],
        pendingTools: inout [String: PendingToolCall]
    ) -> [AgentStreamEvent] {
        guard let type = item["type"] as? String else { return [] }
        switch type {
        case "function_call", "custom_tool_call":
            if let toolCall = toolCall(from: item) {
                removePendingTool(toolCall, pendingTools: &pendingTools)
                return [
                    .toolUseComplete(id: toolCall.callID, name: toolCall.name, inputJSON: toolCall.arguments.isEmpty ? "{}" : toolCall.arguments),
                    .messageStop(stopReason: .toolUse),
                ]
            }
        case "message":
            return []
        default:
            break
        }
        return []
    }

    private static func recordPendingTool(from item: [String: Any], pendingTools: inout [String: PendingToolCall]) {
        guard let toolCall = toolCall(from: item) else { return }
        pendingTools[toolCall.itemID] = toolCall
    }

    private static func appendToolArgumentDelta(from event: [String: Any], pendingTools: inout [String: PendingToolCall]) {
        guard let itemID = (event["item_id"] as? String) ?? (event["call_id"] as? String),
              let delta = event["delta"] as? String else { return }
        let callID = (event["call_id"] as? String) ?? pendingTools[itemID]?.callID ?? itemID
        var pending = pendingTools[itemID] ?? PendingToolCall(itemID: itemID, callID: callID, name: "", arguments: "")
        if pending.callID.isEmpty {
            pending.callID = callID
        }
        pending.arguments += delta
        pendingTools[itemID] = pending
    }

    private static func toolCall(from item: [String: Any]) -> PendingToolCall? {
        guard let name = item["name"] as? String, !name.isEmpty else { return nil }
        let itemID = (item["id"] as? String) ?? (item["call_id"] as? String) ?? name
        let callID = (item["call_id"] as? String) ?? itemID
        let arguments = (item["arguments"] as? String) ?? (item["input"] as? String) ?? ""
        return PendingToolCall(itemID: itemID, callID: callID, name: name, arguments: arguments)
    }

    private static func removePendingTool(_ toolCall: PendingToolCall, pendingTools: inout [String: PendingToolCall]) {
        pendingTools.removeValue(forKey: toolCall.itemID)
        pendingTools.removeValue(forKey: toolCall.callID)
    }

    private static func flushPendingTools(pendingTools: inout [String: PendingToolCall]) -> [AgentStreamEvent] {
        let tools = pendingTools.values
            .filter { !$0.name.isEmpty }
            .sorted { $0.itemID < $1.itemID }
        pendingTools.removeAll()
        return tools.map {
            .toolUseComplete(id: $0.callID.isEmpty ? $0.itemID : $0.callID, name: $0.name, inputJSON: $0.arguments.isEmpty ? "{}" : $0.arguments)
        }
    }

    private static func failedResponseMessage(_ event: [String: Any]) -> String {
        guard let response = event["response"] as? [String: Any],
              let error = response["error"] as? [String: Any] else {
            return "Response failed."
        }
        return errorMessage(error)
    }

    private static func errorMessage(_ error: [String: Any]) -> String {
        (error["message"] as? String) ?? "Unknown stream error"
    }
}
