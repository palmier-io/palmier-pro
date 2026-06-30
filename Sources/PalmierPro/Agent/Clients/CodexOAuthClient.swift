import Foundation

extension Notification.Name {
    static let codexOAuthSettingsChanged = Notification.Name("codexOAuthSettingsChanged")
}

struct CodexOAuthSettings: Equatable, Sendable {
    static let modelDefaultsKey = "codexOAuthModel"
    static let defaultBaseURL = "https://chatgpt.com/backend-api/codex"
    static let defaultModel = "gpt-5.5"

    let endpoint: URL
    let model: String
    let hasCredentials: Bool

    static func load() -> CodexOAuthSettings? {
        let model = savedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              let endpoint = CodexResponsesEndpoint.normalizedURL(from: defaultBaseURL) else { return nil }
        return CodexOAuthSettings(
            endpoint: endpoint,
            model: model,
            hasCredentials: CodexOAuthCredentialStore.hasCredentials
        )
    }

    static var savedModel: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey) ?? defaultModel
    }

    static func save(model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? defaultModel : trimmed, forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .codexOAuthSettingsChanged, object: nil)
    }
}

enum CodexResponsesEndpoint {
    static func normalizedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil else { return nil }

        var pathParts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if pathParts.last == "responses" {
            return components.url
        }
        pathParts.append("responses")
        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }
}

enum CodexOAuthCredentialError: LocalizedError {
    case missingAuthFile(String)
    case invalidAuthFile(String)
    case missingAccessToken
    case missingRefreshToken
    case refreshFailed(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAuthFile(let path): "Run `codex login` first. Codex auth file not found at \(path)."
        case .invalidAuthFile(let path): "Codex auth file could not be read at \(path)."
        case .missingAccessToken: "Run `codex login` first. Codex OAuth token is missing."
        case .missingRefreshToken: "Run `codex login` again. Codex OAuth refresh token is missing."
        case .refreshFailed(let status, let body): "Codex OAuth refresh failed (\(status)): \(body.prefix(500))"
        }
    }
}

struct CodexOAuthCredential: Sendable {
    let accessToken: String
    let accountID: String?
}

enum CodexOAuthCredentialStore {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "c0032de5-a817-4b32-b8e0-94a35fe05c0d"
    private static let tokenExpiryGrace: TimeInterval = 60

    static var hasCredentials: Bool {
        guard let authFile = try? readAuthFile() else { return false }
        return !(authFile.tokens?.accessToken ?? "").isEmpty || !(authFile.tokens?.refreshToken ?? "").isEmpty
    }

    static func credential() async throws -> CodexOAuthCredential {
        var authFile = try readAuthFile()
        if let accessToken = authFile.tokens?.accessToken,
           !accessToken.isEmpty,
           !isExpired(accessToken, grace: tokenExpiryGrace) {
            return CodexOAuthCredential(accessToken: accessToken, accountID: authFile.accountID)
        }

        let refreshed = try await refresh(authFile)
        authFile.apply(refreshed)
        try writeAuthFile(authFile)
        guard let accessToken = authFile.tokens?.accessToken, !accessToken.isEmpty else {
            throw CodexOAuthCredentialError.missingAccessToken
        }
        return CodexOAuthCredential(accessToken: accessToken, accountID: authFile.accountID)
    }

    static func authFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CODEX_AUTH_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        let home = env["CODEX_HOME"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("auth.json", isDirectory: false)
    }

    private static func readAuthFile() throws -> CodexAuthFile {
        let url = authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexOAuthCredentialError.missingAuthFile(url.path)
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CodexAuthFile.self, from: data)
        } catch {
            throw CodexOAuthCredentialError.invalidAuthFile(url.path)
        }
    }

    private static func writeAuthFile(_ authFile: CodexAuthFile) throws {
        let url = authFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(authFile)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func refresh(_ authFile: CodexAuthFile) async throws -> CodexOAuthRefreshResponse {
        guard let refreshToken = authFile.tokens?.refreshToken, !refreshToken.isEmpty else {
            throw CodexOAuthCredentialError.missingRefreshToken
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = formURLEncoded([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CodexOAuthCredentialError.refreshFailed(status: http.statusCode, body: body)
        }
        return try JSONDecoder().decode(CodexOAuthRefreshResponse.self, from: data)
    }

    private static func formURLEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func isExpired(_ jwt: String, grace: TimeInterval) -> Bool {
        guard let exp = jwtPayload(jwt)?["exp"] as? Double else { return false }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow <= grace
    }

    static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

private struct CodexAuthFile: Codable {
    var authMode: String?
    var openAIAPIKey: String?
    var tokens: Tokens?
    var lastRefresh: String?

    var accountID: String? {
        if let accountID = tokens?.accountID, !accountID.isEmpty { return accountID }
        if let payload = tokens?.accessToken.flatMap(CodexOAuthCredentialStore.jwtPayload),
           let accountID = Self.accountID(from: payload) {
            return accountID
        }
        if let payload = tokens?.idToken.flatMap(CodexOAuthCredentialStore.jwtPayload),
           let accountID = Self.accountID(from: payload) {
            return accountID
        }
        return nil
    }

    mutating func apply(_ refresh: CodexOAuthRefreshResponse) {
        var next = tokens ?? Tokens()
        next.accessToken = refresh.accessToken
        next.refreshToken = refresh.refreshToken ?? next.refreshToken
        next.idToken = refresh.idToken ?? next.idToken
        next.accountID = refresh.accountID ?? next.accountID
        tokens = next
        lastRefresh = ISO8601DateFormatter().string(from: Date())
    }

    private enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    struct Tokens: Codable {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var accountID: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case accountID = "account_id"
        }
    }

    private static func accountID(from payload: [String: Any]) -> String? {
        if let id = payload["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let id = payload["account_id"] as? String, !id.isEmpty { return id }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any] {
            if let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { return id }
            if let id = auth["account_id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }
}

private struct CodexOAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

enum CodexOAuthClientError: LocalizedError {
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let body): "Codex OAuth API error (\(status)): \(body.prefix(500))"
        case .streamError(let message): "Codex OAuth stream error: \(message)"
        }
    }
}

struct CodexOAuthClient: AgentClient {
    let settings: CodexOAuthSettings
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
        let credential = try await CodexOAuthCredentialStore.credential()

        var request = URLRequest(url: settings.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: CodexResponsesRequestBody.build(
                model: settings.model,
                maxTokens: maxTokens,
                system: system,
                tools: tools,
                messages: messages
            ),
            options: [.sortedKeys]
        )
        AgentDebugLog.trace("codex oauth request host=\(settings.endpoint.host ?? "-") model=\(settings.model) messages=\(messages.count) tools=\(tools.count)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            AgentDebugLog.trace("codex oauth http error status=\(http.statusCode) bodyBytes=\(body.utf8.count)")
            throw CodexOAuthClientError.httpError(status: http.statusCode, body: body)
        }

        try await CodexResponsesSSE.parse(bytes: bytes, continuation: continuation)
    }
}

enum CodexResponsesRequestBody {
    static func build(
        model: String,
        maxTokens: Int,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": inputItems(from: messages),
            "max_output_tokens": maxTokens,
            "stream": true,
            "store": false,
        ]
        let toolBlocks = tools.map {
            [
                "type": "function",
                "name": $0.name,
                "description": $0.description,
                "parameters": $0.inputSchema,
            ]
        }
        if !toolBlocks.isEmpty {
            body["tools"] = toolBlocks
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }
        return body
    }

    private static func inputItems(from messages: [AgentClientMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .user:
                items.append(contentsOf: userInputItems(from: message.content))
            case .assistant:
                items.append(contentsOf: assistantInputItems(from: message.content))
            }
        }
        return items
    }

    private static func userInputItems(from blocks: [[String: Any]]) -> [[String: Any]] {
        var contentParts: [[String: Any]] = []
        var outputItems: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    contentParts.append(["type": "input_text", "text": text])
                }
            case "image":
                if let image = imageInputPart(from: block) {
                    contentParts.append(image)
                }
            case "tool_result":
                if let item = functionCallOutputItem(from: block) {
                    outputItems.append(item)
                }
            default:
                break
            }
        }

        var items: [[String: Any]] = []
        if !contentParts.isEmpty {
            items.append(["type": "message", "role": "user", "content": contentParts])
        }
        items.append(contentsOf: outputItems)
        return items
    }

    private static func assistantInputItems(from blocks: [[String: Any]]) -> [[String: Any]] {
        var textParts: [String] = []
        var functionCalls: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            case "tool_use":
                if let item = functionCallItem(from: block) {
                    functionCalls.append(item)
                }
            default:
                break
            }
        }

        var items: [[String: Any]] = []
        let content = textParts.joined()
        if !content.isEmpty {
            items.append([
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": content]],
            ])
        }
        items.append(contentsOf: functionCalls)
        return items
    }

    private static func imageInputPart(from block: [String: Any]) -> [String: Any]? {
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

    private static func functionCallItem(from block: [String: Any]) -> [String: Any]? {
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

    private static func functionCallOutputItem(from block: [String: Any]) -> [String: Any]? {
        guard let id = block["tool_use_id"] as? String, !id.isEmpty else { return nil }
        let contentBlocks = block["content"] as? [[String: Any]] ?? []
        let output = contentBlocks.compactMap(toolResultText).joined(separator: "\n")
        return [
            "type": "function_call_output",
            "call_id": id,
            "output": output,
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
        var id: String
        var name: String
        var arguments: String
    }

    struct State {
        var pendingTools: [String: PendingToolCall] = [:]
        var outputKeys: [Int: String] = [:]
        var emittedTool: Bool = false
    }

    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var state = State()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events = try events(fromDataLine: line, state: &state)
            for event in events {
                continuation.yield(event)
            }
        }
        AgentDebugLog.trace("codex responses sse eof pending=\(state.pendingTools.count)")
        for event in finishStream(state: &state) {
            continuation.yield(event)
        }
    }

    static func events(fromDataLine line: String, state: inout State) throws -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else {
            AgentDebugLog.trace("codex responses sse done pending=\(state.pendingTools.count)")
            return finishStream(state: &state)
        }
        guard let data = payload.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if let error = event["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Unknown stream error"
            throw CodexOAuthClientError.streamError(message)
        }

        guard let type = event["type"] as? String else { return [] }
        var out: [AgentStreamEvent] = []
        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                out.append(.textDelta(delta))
            }
        case "response.function_call_arguments.delta":
            appendFunctionArgumentsDelta(event, state: &state)
        case "response.output_item.added", "response.output_item.done":
            appendOutputItemEvent(event, state: &state, output: &out, shouldFlush: type == "response.output_item.done")
        case "response.completed":
            appendCompletedEvents(state: &state, output: &out)
        case "response.incomplete":
            appendIncompleteEvents(event, state: &state, output: &out)
        case "response.failed":
            throw CodexOAuthClientError.streamError(responseErrorMessage(event) ?? "Response failed")
        default:
            break
        }
        return out
    }

    static func finishStream(state: inout State) -> [AgentStreamEvent] {
        var out: [AgentStreamEvent] = []
        let emitted = flushPendingToolEvents(state: &state, output: &out)
        if emitted || state.emittedTool {
            out.append(.messageStop(stopReason: .toolUse))
        }
        return out
    }

    private static func appendFunctionArgumentsDelta(_ event: [String: Any], state: inout State) {
        let key: String
        if let outputIndex = event["output_index"] as? Int,
           let mappedKey = state.outputKeys[outputIndex] {
            key = mappedKey
        } else {
            key = toolKey(from: event)
        }
        var pending = state.pendingTools[key] ?? PendingToolCall(id: "", name: "", arguments: "")
        if let delta = event["delta"] as? String {
            pending.arguments += delta
        }
        state.pendingTools[key] = pending
    }

    private static func appendOutputItemEvent(
        _ event: [String: Any],
        state: inout State,
        output: inout [AgentStreamEvent],
        shouldFlush: Bool
    ) {
        guard let item = event["item"] as? [String: Any],
              item["type"] as? String == "function_call" else { return }

        let key = toolKey(from: event, item: item)
        if let outputIndex = event["output_index"] as? Int {
            state.outputKeys[outputIndex] = key
        }
        var pending = state.pendingTools[key] ?? PendingToolCall(id: "", name: "", arguments: "")
        if let id = item["call_id"] as? String, !id.isEmpty { pending.id = id }
        if pending.id.isEmpty, let id = item["id"] as? String, !id.isEmpty { pending.id = id }
        if let name = item["name"] as? String, !name.isEmpty { pending.name = name }
        if let arguments = item["arguments"] as? String, !arguments.isEmpty { pending.arguments = arguments }
        state.pendingTools[key] = pending

        if shouldFlush {
            flushTool(key: key, state: &state, output: &output)
        }
    }

    private static func appendCompletedEvents(state: inout State, output: inout [AgentStreamEvent]) {
        let emitted = flushPendingToolEvents(state: &state, output: &output)
        output.append(.messageStop(stopReason: emitted || state.emittedTool ? .toolUse : .endTurn))
    }

    private static func appendIncompleteEvents(
        _ event: [String: Any],
        state: inout State,
        output: inout [AgentStreamEvent]
    ) {
        let emitted = flushPendingToolEvents(state: &state, output: &output)
        if emitted || state.emittedTool {
            output.append(.messageStop(stopReason: .toolUse))
            return
        }
        if let response = event["response"] as? [String: Any],
           let details = response["incomplete_details"] as? [String: Any],
           details["reason"] as? String == "max_output_tokens" {
            output.append(.messageStop(stopReason: .maxTokens))
        } else {
            output.append(.messageStop(stopReason: .other))
        }
    }

    private static func flushPendingToolEvents(state: inout State, output: inout [AgentStreamEvent]) -> Bool {
        var emitted = false
        for key in state.pendingTools.keys.sorted() {
            emitted = flushTool(key: key, state: &state, output: &output) || emitted
        }
        return emitted
    }

    @discardableResult
    private static func flushTool(key: String, state: inout State, output: inout [AgentStreamEvent]) -> Bool {
        guard let pending = state.pendingTools.removeValue(forKey: key),
              !pending.name.isEmpty else { return false }
        output.append(.toolUseComplete(
            id: pending.id.isEmpty ? key : pending.id,
            name: pending.name,
            inputJSON: pending.arguments.isEmpty ? "{}" : pending.arguments
        ))
        state.emittedTool = true
        AgentDebugLog.trace("codex responses sse flush tool name=\(pending.name) id=\(pending.id.isEmpty ? key : pending.id) argBytes=\(pending.arguments.utf8.count)")
        return true
    }

    private static func toolKey(from event: [String: Any], item: [String: Any]? = nil) -> String {
        if let itemID = item?["id"] as? String, !itemID.isEmpty { return itemID }
        if let callID = item?["call_id"] as? String, !callID.isEmpty { return callID }
        if let itemID = event["item_id"] as? String, !itemID.isEmpty { return itemID }
        if let outputIndex = event["output_index"] as? Int { return "output_\(outputIndex)" }
        return "output_0"
    }

    private static func responseErrorMessage(_ event: [String: Any]) -> String? {
        if let response = event["response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }
}
