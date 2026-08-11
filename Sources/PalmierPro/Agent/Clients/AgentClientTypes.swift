import Foundation

extension Notification.Name {
    static let agentAPIKeyChanged = Notification.Name("agentAPIKeyChanged")
}

enum AgentProvider: String, CaseIterable, Sendable {
    case anthropic
    case openAI

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

    private var credentialStorage: (account: String, environment: String) {
        switch self {
        case .anthropic: ("anthropic-api-key", "ANTHROPIC_API_KEY")
        case .openAI: ("openai-api-key", "OPENAI_API_KEY")
        }
    }

    fileprivate var storedAPIKey: String {
        #if DEBUG
        let environmentValue = ProcessInfo.processInfo.environment[credentialStorage.environment]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environmentValue.isEmpty { return environmentValue }
        #endif
        return KeychainStore.load(account: credentialStorage.account) ?? ""
    }

    @concurrent
    func loadAPIKey() async -> String {
        storedAPIKey
    }

    @concurrent
    func setAPIKey(_ key: String?) async {
        if let key {
            KeychainStore.save(key, account: credentialStorage.account)
        } else {
            KeychainStore.delete(account: credentialStorage.account)
        }
        NotificationCenter.default.post(name: .agentAPIKeyChanged, object: rawValue)
    }
}

enum AgentReasoningEffort: String, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xHigh = "xhigh"
    case max

    var labelKey: String {
        switch self {
        case .none: L10n.key("None")
        case .minimal: L10n.key("Minimal")
        case .low: L10n.key("Low")
        case .medium: L10n.key("Medium")
        case .high: L10n.key("High")
        case .xHigh: L10n.key("X High")
        case .max: L10n.key("Max")
        }
    }
}

enum AgentModel: String, CaseIterable, Codable, Sendable {
    case sonnet5 = "claude-sonnet-5"
    case opus5 = "claude-opus-5"
    case fable5 = "claude-fable-5"
    case luna = "gpt-5.6-luna"
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"

    static let defaultModel: AgentModel = .terra

    var displayName: String {
        switch self {
        case .sonnet5: "Sonnet 5"
        case .opus5: "Opus 5"
        case .fable5: "Fable 5"
        case .luna: "GPT-5.6 Luna"
        case .terra: "GPT-5.6 Terra"
        case .sol: "GPT-5.6 Sol"
        }
    }

    var provider: AgentProvider {
        switch self {
        case .sonnet5, .opus5, .fable5: .anthropic
        case .luna, .terra, .sol: .openAI
        }
    }

    var maxOutputTokens: Int { 64_000 }

    var requiresPaidHostedPlan: Bool {
        self == .fable5 || self == .sol
    }

    static func persisted(_ rawValue: String) -> AgentModel? {
        rawValue == "claude-opus-4-8" ? .opus5 : AgentModel(rawValue: rawValue)
    }

    var supportedReasoningEfforts: [AgentReasoningEffort] {
        switch provider {
        case .anthropic:
            [.low, .medium, .high, .xHigh, .max]
        case .openAI:
            AgentReasoningEffort.allCases
        }
    }

}

struct AgentRunSettings: Equatable, Sendable {
    let model: AgentModel
    let reasoningEffort: AgentReasoningEffort
}

enum AgentReasoningPreferences {
    static func effort(for model: AgentModel, defaults: UserDefaults) -> AgentReasoningEffort {
        guard let rawValue = defaults.string(forKey: key("effort", model: model)),
              let effort = AgentReasoningEffort(rawValue: rawValue),
              model.supportedReasoningEfforts.contains(effort)
        else { return .medium }
        return effort
    }

    static func set(_ effort: AgentReasoningEffort, for model: AgentModel, defaults: UserDefaults) {
        defaults.set(effort.rawValue, forKey: key("effort", model: model))
    }

    private static func key(_ setting: String, model: AgentModel) -> String {
        "agentReasoning.\(setting).\(model.rawValue)"
    }
}

enum AgentRoute: Equatable, Sendable {
    case direct
    case hosted
    case unavailable
}

enum AgentRouting {
    static func route(
        model: AgentModel,
        credentials: AgentCredentialSnapshot,
        hasHostedCredits: Bool,
        hasPaidPlan: Bool
    ) -> AgentRoute {
        if !credentials[model.provider].isEmpty { return .direct }
        if model.requiresPaidHostedPlan && !hasPaidPlan { return .unavailable }
        return hasHostedCredits ? .hosted : .unavailable
    }
}

struct AgentCredentialSnapshot: Equatable, Sendable {
    private let apiKeys: [AgentProvider: String]

    init(_ apiKeys: [AgentProvider: String] = [:]) {
        self.apiKeys = apiKeys
    }

    subscript(provider: AgentProvider) -> String {
        apiKeys[provider, default: ""]
    }

    @concurrent
    static func loadFromKeychain() async -> AgentCredentialSnapshot {
        AgentCredentialSnapshot(Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map {
            ($0, $0.storedAPIKey)
        }))
    }
}

enum AgentStopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case other
}

struct AgentRequestMessage: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [AgentRequestBlock]
}

enum AgentRequestBlock: Sendable {
    case content(AgentContentBlock)
    case image(base64: String, mediaType: String)
}

struct AgentToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

struct AgentRequestContext: Equatable, Sendable {
    let conversationID: UUID
    let traceID: UUID
    let spanID: UUID
    let inputMessageID: UUID
    let outputMessageID: UUID
    let projectID: String?

    func apply(to request: inout URLRequest, telemetryEnabled: Bool) {
        request.setValue(conversationID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Conversation-Id")
        request.setValue(traceID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Trace-Id")
        request.setValue(spanID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Span-Id")
        request.setValue(inputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Input-Message-Id")
        request.setValue(outputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Output-Message-Id")
        if let projectID, !projectID.isEmpty {
            request.setValue(projectID, forHTTPHeaderField: "X-Palmier-Project-Id")
        }
        request.setValue(telemetryEnabled ? "1" : "0", forHTTPHeaderField: "X-Palmier-Agent-Telemetry")
    }
}

enum AgentStreamEvent: Equatable, Sendable {
    case thinkingDelta(String)
    case thinkingSignature(String)
    case redactedThinking(String)
    case reasoningSummaryDelta(String)
    case reasoningComplete(itemID: String?, summary: String, encryptedContent: String)
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case messageStop(stopReason: AgentStopReason)
}

enum AgentClientTransportError: LocalizedError {
    case missingAPIKey(AgentProvider)
    case httpError(provider: AgentProvider, status: Int, body: String)
    case streamError(provider: AgentProvider, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "No \(provider.displayName) API key is set."
        case .httpError(let provider, let status, let body):
            "\(provider.displayName) API error (\(status)): \(body.prefix(500))"
        case .streamError(let provider, let message):
            "\(provider.displayName) stream error: \(message)"
        }
    }
}

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

func makeAgentStream(
    _ operation: @escaping @Sendable (
        AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> Void
) -> AsyncThrowingStream<AgentStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await operation(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

enum AgentHTTP {
    static let streamIdleTimeout: TimeInterval = 600

    static func bytes(
        for request: URLRequest,
        makeError: (Int, String) -> any Error
    ) async throws -> URLSession.AsyncBytes {
        var request = request
        request.timeoutInterval = streamIdleTimeout
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode >= 400 else {
            return bytes
        }
        var body = ""
        for try await line in bytes.lines { body += line + "\n" }
        throw makeError(response.statusCode, body)
    }
}

extension AgentRunSettings {
    func requestBody(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> [String: Any] {
        switch model.provider {
        case .anthropic:
            AnthropicRequestBody.build(
                model: model,
                reasoningEffort: reasoningEffort,
                system: system,
                tools: tools,
                messages: messages
            )
        case .openAI:
            OpenAIRequestBody.build(
                model: model,
                reasoningEffort: reasoningEffort,
                system: system,
                tools: tools,
                messages: messages
            )
        }
    }
}

extension AgentProvider {
    func parseSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        switch self {
        case .anthropic:
            try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
        case .openAI:
            try await OpenAISSE.parse(bytes: bytes, continuation: continuation)
        }
    }
}
