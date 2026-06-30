import Foundation

// MARK: - Shared value types

extension Notification.Name {
    static let agentProviderChanged = Notification.Name("agentProviderChanged")
}

enum AgentProviderPreference: String, CaseIterable, Identifiable, Sendable {
    case palmier
    case anthropic
    case openAICompatible
    case zhipu
    case codexOAuth

    static let defaultsKey = "agentProvider"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .palmier: "Palmier"
        case .anthropic: "Anthropic"
        case .openAICompatible: "OpenAI Compatible"
        case .zhipu: "Zhipu GLM"
        case .codexOAuth: "Codex OAuth"
        }
    }

    var usesOpenAICompatibleProtocol: Bool {
        switch self {
        case .openAICompatible, .zhipu, .codexOAuth:
            return true
        case .anthropic, .palmier:
            return false
        }
    }

    static var stored: AgentProviderPreference? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return AgentProviderPreference(rawValue: raw)
    }

    static func save(_ provider: AgentProviderPreference) {
        UserDefaults.standard.set(provider.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: .agentProviderChanged, object: nil)
    }

    static func defaultProvider(
        hasAnthropicKey: Bool,
        hasOpenAICompatibleConfig: Bool,
        hasZhipuConfig: Bool = false,
        hasCodexOAuthConfig: Bool = false
    ) -> AgentProviderPreference {
        if let stored { return stored }
        if hasOpenAICompatibleConfig { return .openAICompatible }
        if hasZhipuConfig { return .zhipu }
        if hasCodexOAuthConfig { return .codexOAuth }
        if hasAnthropicKey { return .anthropic }
        return .palmier
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

struct AgentClientMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [[String: Any]]
}

struct AgentToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum AgentStreamEvent: Sendable {
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case messageStop(stopReason: AgentStopReason)
}

// MARK: - Client protocol

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// MARK: - Usage logging

enum AgentUsageLog {
    static func record(_ usage: [String: Any]) {
        #if DEBUG
        let input = usage["input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let billed = input + cacheWrite + cacheRead
        let readPct = billed > 0 ? Int((Double(cacheRead) / Double(billed)) * 100) : 0
        print("[agent cache] input=\(input) cacheWrite=\(cacheWrite) cacheRead=\(cacheRead) (\(readPct)% read)")
        #endif
    }
}

enum AgentDebugLog {
    static func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["PALMIER_AGENT_DEBUG"] == "1" else { return }
        print("[agent-debug] \(message())")
        #endif
    }
}
