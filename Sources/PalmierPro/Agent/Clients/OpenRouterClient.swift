import Foundation

struct OpenRouterClient: AgentClient {
    let apiKey: String
    let model: String
    var maxTokens: Int = 8192

    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

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
        guard !apiKey.isEmpty else { throw OpenRouterClientError.missingAPIKey }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")

        let body = try Self.buildBody(system: system, tools: tools, messages: messages, model: model, maxTokens: maxTokens)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var bodyText = ""
            for try await line in bytes.lines { bodyText += line + "\n" }
            throw OpenRouterClientError.httpError(status: http.statusCode, body: bodyText)
        }

        try await OpenAISSE.parse(bytes: bytes, continuation: continuation)
    }

    // MARK: - OpenAI-format body builder

    private static func buildBody(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        model: String,
        maxTokens: Int
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        if !system.isEmpty {
            body["system"] = system
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ],
                ]
            }
        }

        body["messages"] = Self.translateMessages(messages)
        return body
    }

    // MARK: - Message translation (Anthropic → OpenAI)

    static func translateMessages(_ messages: [AnthropicMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for msg in messages {
            out.append(contentsOf: translateOne(msg))
        }
        return out
    }

    private static func translateOne(_ msg: AnthropicMessage) -> [[String: Any]] {
        var textBlocks: [[String: Any]] = []
        var toolUseBlocks: [(id: String, name: String, inputJSON: String)] = []
        var toolResultBlocks: [(id: String, content: String, isError: Bool)] = []

        for block in msg.content {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textBlocks.append(["type": "text", "text": text])
                }
            case "image":
                if let source = block["source"] as? [String: Any],
                   let sourceType = source["type"] as? String,
                   sourceType == "base64",
                   let mediaType = source["media_type"] as? String,
                   let data = source["data"] as? String {
                    let dataURL = "data:\(mediaType);base64,\(data)"
                    textBlocks.append(["type": "image_url", "image_url": ["url": dataURL]])
                }
            case "tool_use":
                if let id = block["id"] as? String,
                   let name = block["name"] as? String,
                   let input = block["input"] {
                    let json = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolUseBlocks.append((id, name, json))
                }
            case "tool_result":
                if let toolUseId = block["tool_use_id"] as? String,
                   let contentArr = block["content"] as? [[String: Any]] {
                    let text = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    let isError = block["is_error"] as? Bool ?? false
                    toolResultBlocks.append((toolUseId, text, isError))
                }
            default:
                break
            }
        }

        var result: [[String: Any]] = []

        if !toolResultBlocks.isEmpty {
            for tr in toolResultBlocks {
                var entry: [String: Any] = [
                    "role": "tool",
                    "tool_call_id": tr.id,
                    "content": tr.content,
                ]
                if tr.isError {
                    entry["content"] = "Error: \(tr.content)"
                }
                result.append(entry)
            }
        } else {
            let role = msg.role.rawValue

            if !toolUseBlocks.isEmpty {
                var entry: [String: Any] = ["role": role]
                if !textBlocks.isEmpty {
                    entry["content"] = textBlocks
                } else {
                    entry["content"] = nil
                }
                entry["tool_calls"] = toolUseBlocks.map { tc in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.name,
                            "arguments": tc.inputJSON,
                        ],
                    ]
                }
                result.append(entry)
            } else {
                let content: Any
                if textBlocks.isEmpty {
                    content = ""
                } else if textBlocks.count == 1, textBlocks[0]["type"] as? String == "text" {
                    content = textBlocks[0]["text"] as? String ?? ""
                } else {
                    content = textBlocks
                }
                result.append(["role": role, "content": content])
            }
        }

        return result
    }
}

// MARK: - OpenAI SSE stream parser

enum OpenAISSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishedToolIds: Set<Int> = []
        var didStop = false

        for try await line in bytes.lines {
            try Task.checkCancellation()

            if line == "data: [DONE]" { break }

            guard line.hasPrefix("data:"),
                  let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }

            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    guard let index = tc["index"] as? Int else { continue }

                    if let id = tc["id"] as? String, let fn = tc["function"] as? [String: Any],
                       let name = fn["name"] as? String {
                        pendingToolCalls[index] = (id, name, "")
                        finishedToolIds.remove(index)
                    }

                    if var acc = pendingToolCalls[index],
                       let fn = tc["function"] as? [String: Any],
                       let argsDelta = fn["arguments"] as? String {
                        acc.arguments += argsDelta
                        pendingToolCalls[index] = acc
                    }
                }
            }

            if let finishReasonText = choice["finish_reason"] as? String, !finishReasonText.isEmpty {
                didStop = true
                for (idx, acc) in pendingToolCalls where !finishedToolIds.contains(idx) {
                    let json = acc.arguments.isEmpty ? "{}" : acc.arguments
                    continuation.yield(.toolUseComplete(id: acc.id, name: acc.name, inputJSON: json))
                    finishedToolIds.insert(idx)
                }
                let reason = Self.mapStopReason(finishReasonText)
                continuation.yield(.messageStop(stopReason: reason))
            }
        }

        guard !didStop else { return }

        for (idx, acc) in pendingToolCalls where !finishedToolIds.contains(idx) {
            let json = acc.arguments.isEmpty ? "{}" : acc.arguments
            continuation.yield(.toolUseComplete(id: acc.id, name: acc.name, inputJSON: json))
        }
        continuation.yield(.messageStop(stopReason: .endTurn))
    }

    static func mapStopReason(_ raw: String) -> AnthropicStopReason {
        switch raw {
        case "stop": .endTurn
        case "length": .maxTokens
        case "tool_calls": .toolUse
        case "content_filter": .refusal
        default: .other
        }
    }
}
