import Foundation

extension Notification.Name {
    static let agentAPIKeyChanged = Notification.Name("agentAPIKeyChanged")
}

enum AgentProvider: String, CaseIterable, Codable, Sendable {
    case anthropic
    case openAI

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

    var defaultBaseURLString: String {
        switch self {
        case .anthropic: "https://api.anthropic.com"
        case .openAI: "https://api.openai.com/v1"
        }
    }

    private var chatPathComponents: [String] {
        switch self {
        case .anthropic: ["v1", "messages"]
        case .openAI: ["responses"]
        }
    }

    func chatEndpoint(baseURLString: String?) -> URL {
        let trimmed = baseURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = trimmed.isEmpty ? defaultBaseURLString : trimmed
        if let endpoint = endpoint(fromBase: candidate) {
            return endpoint
        }
        return endpoint(fromBase: defaultBaseURLString)!
    }

    private func endpoint(fromBase base: String) -> URL? {
        let normalized = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var url = URL(string: normalized), url.scheme != nil, url.host != nil else {
            return nil
        }
        for component in chatPathComponents {
            url.append(path: component)
        }
        return url
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
    @discardableResult
    func setAPIKey(_ key: String?) async -> Bool {
        let account = credentialStorage.account
        if let key {
            guard KeychainStore.save(key, account: account) else { return false }
            guard KeychainStore.load(account: account) == key else {
                Log.agent.error("keychain save could not be read back account=\(account)")
                return false
            }
        } else {
            guard KeychainStore.delete(account: account) else { return false }
        }
        NotificationCenter.default.post(name: .agentAPIKeyChanged, object: rawValue)
        return true
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
    let model: AgentChatModel
    let reasoningEffort: AgentReasoningEffort

    init(model: AgentChatModel, reasoningEffort: AgentReasoningEffort) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    init(model: AgentModel, reasoningEffort: AgentReasoningEffort) {
        self.init(model: .builtIn(model), reasoningEffort: reasoningEffort)
    }
}

enum AgentReasoningPreferences {
    static func effort(for model: AgentChatModel, defaults: UserDefaults) -> AgentReasoningEffort {
        effort(forPersistenceToken: model.persistenceToken, model: model, defaults: defaults)
    }

    static func effort(for model: AgentModel, defaults: UserDefaults) -> AgentReasoningEffort {
        effort(for: .builtIn(model), defaults: defaults)
    }

    static func set(_ effort: AgentReasoningEffort, for model: AgentChatModel, defaults: UserDefaults) {
        defaults.set(effort.rawValue, forKey: key(model.persistenceToken))
    }

    static func set(_ effort: AgentReasoningEffort, for model: AgentModel, defaults: UserDefaults) {
        set(effort, for: .builtIn(model), defaults: defaults)
    }

    private static func effort(
        forPersistenceToken token: String,
        model: AgentChatModel,
        defaults: UserDefaults
    ) -> AgentReasoningEffort {
        guard let rawValue = defaults.string(forKey: key(token)),
              let effort = AgentReasoningEffort(rawValue: rawValue),
              model.supportedReasoningEfforts.contains(effort)
        else { return .medium }
        return effort
    }

    private static func key(_ persistenceToken: String) -> String {
        "agentReasoning.effort.\(persistenceToken)"
    }
}

enum AgentBaseURLPreferences {
    static func storedString(for provider: AgentProvider, defaults: UserDefaults) -> String {
        defaults.string(forKey: key(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func set(_ value: String?, for provider: AgentProvider, defaults: UserDefaults) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == provider.defaultBaseURLString {
            defaults.removeObject(forKey: key(for: provider))
        } else {
            defaults.set(trimmed, forKey: key(for: provider))
        }
    }

    static func chatEndpoint(for provider: AgentProvider, defaults: UserDefaults) -> URL {
        provider.chatEndpoint(baseURLString: storedString(for: provider, defaults: defaults))
    }

    private static func key(for provider: AgentProvider) -> String {
        "agentBaseURL.\(provider.rawValue)"
    }
}

enum AgentRoute: Equatable, Sendable {
    case direct
    case hosted
    case unavailable
}

enum AgentRouting {
    static func route(
        model: AgentChatModel,
        credentials: AgentCredentialSnapshot,
        hasHostedCredits: Bool,
        hasPaidPlan: Bool
    ) -> AgentRoute {
        if !credentials[model.provider].isEmpty { return .direct }
        // Custom models are BYOK-only; hosted backend only knows built-in IDs.
        if model.isCustom { return .unavailable }
        if model.requiresPaidHostedPlan && !hasPaidPlan { return .unavailable }
        return hasHostedCredits ? .hosted : .unavailable
    }

    static func route(
        model: AgentModel,
        credentials: AgentCredentialSnapshot,
        hasHostedCredits: Bool,
        hasPaidPlan: Bool
    ) -> AgentRoute {
        route(
            model: .builtIn(model),
            credentials: credentials,
            hasHostedCredits: hasHostedCredits,
            hasPaidPlan: hasPaidPlan
        )
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

    func apply(to request: inout URLRequest) {
        request.setValue(conversationID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Conversation-Id")
        request.setValue(traceID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Trace-Id")
        request.setValue(spanID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Span-Id")
        request.setValue(inputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Input-Message-Id")
        request.setValue(outputMessageID.uuidString.lowercased(), forHTTPHeaderField: "X-Palmier-Output-Message-Id")
        if let projectID, !projectID.isEmpty {
            request.setValue(projectID, forHTTPHeaderField: "X-Palmier-Project-Id")
        }
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
