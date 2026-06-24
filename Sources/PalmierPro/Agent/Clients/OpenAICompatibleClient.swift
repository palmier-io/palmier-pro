import Foundation
import AgentTranslation

extension Notification.Name {
    static let openRouterAPIKeyChanged = Notification.Name("openRouterAPIKeyChanged")
}

enum OpenRouterKeychain {
    private static let account = "openrouter-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .openRouterAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .openRouterAPIKeyChanged, object: nil)
    }
}

// MARK: - Config

struct OpenAICompatibleConfig: Sendable {
    var baseURL: URL
    var apiKey: String
    var model: String
    var maxTokens: Int
    var enablePromptCache: Bool
    var temperature: Double?
    var referer: String?
    var appTitle: String?

    static let defaultModel = "google/gemini-2.5-flash-lite"
    static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let modelDefaultsKey = "agentOpenRouterModel"

    /// Builds the active config from keychain + overrides, or nil when no key is set.
    static func resolved() -> OpenAICompatibleConfig? {
        guard let key = OpenRouterKeychain.load(), !key.isEmpty else { return nil }
        let model = UserDefaults.standard.string(forKey: modelDefaultsKey)
            ?? infoString("PalmierOpenRouterModel")
            ?? defaultModel
        let base = infoString("PalmierOpenRouterBaseURL").flatMap { URL(string: $0) }
            ?? openRouterBaseURL
        return OpenAICompatibleConfig(
            baseURL: base,
            apiKey: key,
            model: model,
            maxTokens: 8192,
            enablePromptCache: true,
            temperature: nil,
            referer: infoString("PalmierOpenRouterReferer"),
            appTitle: infoString("CFBundleName")
        )
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}

enum OpenAICompatibleError: LocalizedError {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No OpenRouter API key is set."
        case .httpError(let status, let body): "OpenRouter API error (\(status)): \(body.prefix(500))"
        case .streamError(let msg): "Stream error: \(msg)"
        }
    }
}

// MARK: - Client

/// Drives the agent through any OpenAI-compatible Chat Completions endpoint
/// (OpenRouter by default). All Anthropic <-> OpenAI translation and SSE decode
/// lives in the platform-agnostic `AgentTranslation` package; this type only
/// handles transport, the byte stream, and config.
struct OpenAICompatibleClient: AgentClient {
    let config: OpenAICompatibleConfig

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
        guard !config.apiKey.isEmpty else { throw OpenAICompatibleError.missingAPIKey }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        // OpenRouter ranking metadata; harmless on other gateways.
        if let referer = config.referer { request.setValue(referer, forHTTPHeaderField: "HTTP-Referer") }
        if let title = config.appTitle { request.setValue(title, forHTTPHeaderField: "X-Title") }

        let body = OpenAIRequestBuilder.body(
            model: config.model,
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            enablePromptCache: config.enablePromptCache,
            system: system,
            tools: tools.map { AgentToolSchema(name: $0.name, description: $0.description, parameters: $0.inputSchema) },
            turns: messages.map { AgentTurn(role: $0.role == .user ? .user : .assistant, content: $0.content) }
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line + "\n" }
            throw OpenAICompatibleError.httpError(status: http.statusCode, body: errorBody)
        }

        var decoder = OpenAISSEDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events: [AgentStreamEvent]
            do {
                events = try decoder.consume(line: line)
            } catch let OpenAITranslationError.stream(message) {
                throw OpenAICompatibleError.streamError(message)
            }
            for event in events {
                switch event {
                case .text(let text):
                    continuation.yield(.textDelta(text))
                case .toolCall(let id, let name, let argumentsJSON):
                    continuation.yield(.toolUseComplete(id: id, name: name, inputJSON: argumentsJSON))
                case .stop(let reason):
                    continuation.yield(.messageStop(stopReason: Self.mapStopReason(reason)))
                }
            }
        }
    }

    private static func mapStopReason(_ reason: AgentStopReason) -> AnthropicStopReason {
        switch reason {
        case .endTurn: return .endTurn
        case .toolUse: return .toolUse
        case .maxTokens: return .maxTokens
        case .refusal: return .refusal
        case .other: return .other
        }
    }
}
