import Foundation

extension Notification.Name {
    static let agentAPIKeyChanged = Notification.Name("agentAPIKeyChanged")
}

enum AgentProvider: String, CaseIterable, Sendable {
    case anthropic
    case openAI
    case custom

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .custom: "Custom"
        }
    }

    private var credentialStorage: (account: String, environment: String) {
        switch self {
        case .anthropic: ("anthropic-api-key", "ANTHROPIC_API_KEY")
        case .openAI: ("openai-api-key", "OPENAI_API_KEY")
        case .custom: ("custom-agent-api-key", "CUSTOM_AGENT_API_KEY")
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
    /// The user's own OpenAI-compatible endpoint. Its wire model id comes from
    /// `AgentRunSettings.custom`, not from `rawValue`.
    case custom = "custom"

    static let defaultModel: AgentModel = .terra

    var displayName: String {
        switch self {
        case .sonnet5: "Sonnet 5"
        case .opus5: "Opus 5"
        case .fable5: "Fable 5"
        case .luna: "GPT-5.6 Luna"
        case .terra: "GPT-5.6 Terra"
        case .sol: "GPT-5.6 Sol"
        case .custom: "Custom Endpoint"
        }
    }

    var provider: AgentProvider {
        switch self {
        case .sonnet5, .opus5, .fable5: .anthropic
        case .luna, .terra, .sol: .openAI
        case .custom: .custom
        }
    }

    var maxOutputTokens: Int { 64_000 }

    var requiresPaidHostedPlan: Bool {
        switch self {
        case .fable5, .sol: true
        case .sonnet5, .opus5, .luna, .terra, .custom: false
        }
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
        case .custom:
            // A gateway that does not support reasoning ignores the field, and one that does
            // now honours the same low/medium/high the built-in providers offer.
            [.low, .medium, .high]
        }
    }

}

struct AgentRunSettings: Equatable, Sendable {
    let model: AgentModel
    let reasoningEffort: AgentReasoningEffort
    /// Required when `model == .custom`, ignored otherwise.
    var custom: CustomAgentModel?

    init(model: AgentModel, reasoningEffort: AgentReasoningEffort, custom: CustomAgentModel? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.custom = model == .custom ? custom : nil
    }

    var supportsImages: Bool? {
        model == .custom ? custom?.supportsImages : true
    }
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
        hasPaidPlan: Bool,
        custom: CustomAgentModel? = nil,
        customKey: String = "",
        hostedEnabled: Bool = HostedServices.enabled
    ) -> AgentRoute {
        if model == .custom {
            // A configured model is always called directly, and only a loopback host may go
            // without a credential — a remote host must never be called unauthenticated.
            // Each custom model holds its own key, so it cannot come from the provider snapshot.
            guard let custom else { return .unavailable }
            if customKey.isEmpty && !custom.allowsMissingAPIKey { return .unavailable }
            return .direct
        }
        if !credentials[model.provider].isEmpty { return .direct }
        // Hosted access was removed in the backend teardown (R1): local-only routing.
        return .unavailable
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

    var containsImages: Bool {
        content.contains { block in
            switch block {
            case .image: true
            case .content(.toolResult(_, let output, _)): output.contains(where: \.isImage)
            default: false
            }
        }
    }
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
        request.setValue(conversationID.uuidString.lowercased(), forHTTPHeaderField: "X-Compositor-Conversation-Id")
        request.setValue(traceID.uuidString.lowercased(), forHTTPHeaderField: "X-Compositor-Trace-Id")
        request.setValue(spanID.uuidString.lowercased(), forHTTPHeaderField: "X-Compositor-Span-Id")
        request.setValue(inputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Compositor-Input-Message-Id")
        request.setValue(outputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Compositor-Output-Message-Id")
        if let projectID, !projectID.isEmpty {
            request.setValue(projectID, forHTTPHeaderField: "X-Compositor-Project-Id")
        }
        request.setValue(telemetryEnabled ? "1" : "0", forHTTPHeaderField: "X-Compositor-Agent-Telemetry")
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
    case imageInputUnsupported(model: String)
    case httpError(provider: AgentProvider, status: Int, body: String)
    case streamError(provider: AgentProvider, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "No \(provider.displayName) API key is set."
        case .imageInputUnsupported(let model):
            "Model '\(model)' is configured without image input. Use a vision-capable model for this conversation or start a text-only chat."
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
    ) -> AgentStreamOperation
}

struct AgentStreamOperation: Sendable {
    let events: AsyncThrowingStream<AgentStreamEvent, Error>
    private let producer: Task<Void, any Error>

    fileprivate init(events: AsyncThrowingStream<AgentStreamEvent, Error>, producer: Task<Void, any Error>) {
        self.events = events
        self.producer = producer
    }

    func cancel() {
        producer.cancel()
    }

    func join() async -> Result<Void, any Error> {
        await producer.result
    }
}

func makeAgentStream(
    _ operation: @escaping @Sendable (
        AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> Void
) -> AgentStreamOperation {
    let (events, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
    let producer = Task.detached {
        defer { continuation.onTermination = nil }
        do {
            try await operation(continuation)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
    }
    continuation.onTermination = { termination in
        if case .cancelled = termination { producer.cancel() }
    }
    return AgentStreamOperation(events: events, producer: producer)
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
        // The body is the only place a gateway says *why* it refused — wrong key, unknown model,
        // bad request shape. Without it a 401 and a 400 look identical from the outside.
        AgentDiagnostics.httpFailure(
            id: await AgentDiagnostics.currentTurnID,
            host: request.url?.host ?? "unknown",
            status: response.statusCode,
            body: body
        )
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
            return AnthropicRequestBody.build(
                model: model,
                reasoningEffort: reasoningEffort,
                system: system,
                tools: tools,
                messages: messages
            )
        case .openAI:
            return OpenAIRequestBody.build(
                model: model,
                reasoningEffort: reasoningEffort,
                system: system,
                tools: tools,
                messages: messages
            )
        case .custom:
            guard let custom else { return [:] }
            return OpenAIChatCompletionsRequestBody.build(
                modelID: custom.modelID,
                system: system,
                tools: tools,
                messages: messages,
                reasoningEffort: reasoningEffort
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
        case .custom:
            try await OpenAIChatCompletionsSSE.parse(bytes: bytes, continuation: continuation)
        }
    }
}
