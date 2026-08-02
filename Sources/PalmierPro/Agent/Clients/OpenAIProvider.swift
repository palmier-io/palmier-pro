import Foundation

enum OpenAIRequestBody {
    static func build(
        model: AgentModel,
        reasoningEffort: AgentReasoningEffort = .medium,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> [String: Any] {
        precondition(model.provider == .openAI)
        precondition(model.supportedReasoningEfforts.contains(reasoningEffort))
        var body: [String: Any] = [
            "model": model.rawValue,
            "store": false,
            "stream": true,
            "max_output_tokens": model.maxOutputTokens,
            "instructions": system,
            "input": inputItems(messages: messages, model: model),
            "reasoning": ["summary": "auto", "effort": reasoningEffort.rawValue],
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                [
                    "type": "function",
                    "name": $0.name,
                    "description": $0.description,
                    "parameters": $0.inputSchema,
                ]
            }
        }
        return body
    }

    private static func inputItems(messages: [AgentRequestMessage], model: AgentModel) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            var content: [[String: Any]] = []

            func flushMessage() {
                guard !content.isEmpty else { return }
                items.append([
                    "type": "message",
                    "role": message.role.rawValue,
                    "content": content,
                ])
                content.removeAll(keepingCapacity: true)
            }

            for block in message.content {
                switch block {
                case .image(let base64, let mediaType):
                    content.append(inputImageJSON(base64: base64, mediaType: mediaType))
                case .content(let block):
                    switch block {
                    case .thinking, .redactedThinking:
                        continue
                    case .openAIReasoning(let summary, let encryptedContent, let itemID, let reasoningModel):
                        guard reasoningModel == model, !encryptedContent.isEmpty else { continue }
                        flushMessage()
                        var item: [String: Any] = [
                            "type": "reasoning",
                            "encrypted_content": encryptedContent,
                            "summary": summary.isEmpty
                                ? []
                                : [["type": "summary_text", "text": summary]],
                        ]
                        if let itemID, !itemID.isEmpty { item["id"] = itemID }
                        items.append(item)
                    case .text(let text):
                        guard !text.isEmpty else { continue }
                        if message.role == .user {
                            content.append(["type": "input_text", "text": text])
                        } else {
                            content.append(["type": "output_text", "text": text, "annotations": []])
                        }
                    case .toolUse(let id, let name, let inputJSON):
                        flushMessage()
                        items.append([
                            "type": "function_call",
                            "call_id": id,
                            "name": name,
                            "arguments": normalizedJSONObject(inputJSON),
                        ])
                    case .toolResult(let toolUseID, let output, let isError):
                        flushMessage()
                        var outputContent = output.map(toolOutputJSON)
                        if isError {
                            outputContent.insert(["type": "input_text", "text": "Tool error"], at: 0)
                        }
                        items.append([
                            "type": "function_call_output",
                            "call_id": toolUseID,
                            "output": outputContent,
                        ])
                    }
                }
            }
            flushMessage()
        }
        return items
    }

    private static func normalizedJSONObject(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: normalized, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func toolOutputJSON(_ block: ToolResult.Block) -> [String: Any] {
        switch block {
        case .text(let text):
            ["type": "input_text", "text": text]
        case .image(let base64, let mediaType):
            inputImageJSON(base64: base64, mediaType: mediaType)
        }
    }

    private static func inputImageJSON(base64: String, mediaType: String) -> [String: Any] {
        [
            "type": "input_image",
            "image_url": "data:\(mediaType);base64,\(base64)",
        ]
    }
}

enum OpenAISSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var parser = OpenAIStreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try parser.consume(line: line) {
                continuation.yield(event)
            }
        }
        try parser.finish()
    }
}

struct OpenAIStreamParser {
    private(set) var didTerminate = false

    mutating func consume(line: String) throws -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return [] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentClientTransportError.streamError(provider: .openAI, message: "Invalid event payload.")
        }
        return try consume(event: object)
    }

    mutating func consume(event: [String: Any]) throws -> [AgentStreamEvent] {
        guard let type = event["type"] as? String else { return [] }

        switch type {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]

        case "response.reasoning_summary_text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.reasoningSummaryDelta(delta)]

        case "response.refusal.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]

        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any] else { return [] }
            return outputEvents(for: item)

        case "response.completed", "response.incomplete", "response.failed", "response.cancelled":
            didTerminate = true
            let response = event["response"] as? [String: Any] ?? [:]
            return try terminalEvents(eventType: type, response: response)

        case "error":
            didTerminate = true
            let error = event["error"] as? [String: Any]
            throw AgentClientTransportError.streamError(
                provider: .openAI,
                message: error?["message"] as? String ?? event["message"] as? String ?? "Unknown stream error."
            )

        default:
            return []
        }
    }

    func finish() throws {
        guard didTerminate else {
            throw AgentClientTransportError.streamError(
                provider: .openAI,
                message: "The stream ended before a terminal event."
            )
        }
    }

    private func terminalEvents(
        eventType: String,
        response: [String: Any]
    ) throws -> [AgentStreamEvent] {
        let status = response["status"] as? String
        if eventType == "response.failed" || status == "failed" {
            let error = response["error"] as? [String: Any]
            throw AgentClientTransportError.streamError(
                provider: .openAI,
                message: error?["message"] as? String ?? "The response failed."
            )
        }
        if eventType == "response.cancelled" || status == "cancelled" {
            throw CancellationError()
        }
        if eventType == "response.incomplete" || status == "incomplete" {
            return [.messageStop(stopReason: incompleteStopReason(response))]
        }
        return [.messageStop(stopReason: terminalStopReason(response))]
    }

    private func outputEvents(for item: [String: Any]) -> [AgentStreamEvent] {
        switch item["type"] as? String {
        case "function_call":
            guard let callID = item["call_id"] as? String, !callID.isEmpty,
                  let name = item["name"] as? String, !name.isEmpty
            else { return [] }
            let arguments = item["arguments"] as? String ?? "{}"
            return [.toolUseComplete(
                id: callID,
                name: name,
                inputJSON: arguments.isEmpty ? "{}" : arguments
            )]
        case "reasoning":
            guard let encryptedContent = item["encrypted_content"] as? String,
                  !encryptedContent.isEmpty
            else { return [] }
            let summary = (item["summary"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }
                .joined() ?? ""
            return [.reasoningComplete(
                itemID: item["id"] as? String,
                summary: summary,
                encryptedContent: encryptedContent
            )]
        default:
            return []
        }
    }

    private func terminalStopReason(_ response: [String: Any]) -> AgentStopReason {
        let output = response["output"] as? [[String: Any]] ?? []
        if output.contains(where: { $0["type"] as? String == "function_call" }) {
            return .toolUse
        }
        if output.contains(where: { item in
            let content = item["content"] as? [[String: Any]] ?? []
            return content.contains { $0["type"] as? String == "refusal" }
        }) {
            return .refusal
        }
        return .endTurn
    }

    private func incompleteStopReason(_ response: [String: Any]) -> AgentStopReason {
        let details = response["incomplete_details"] as? [String: Any]
        return details?["reason"] as? String == "max_output_tokens" ? .maxTokens : .other
    }

}
