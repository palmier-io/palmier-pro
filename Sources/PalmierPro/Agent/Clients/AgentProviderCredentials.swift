import Foundation

extension Notification.Name {
    static let zhipuAgentSettingsChanged = Notification.Name("zhipuAgentSettingsChanged")
    static let codexOAuthAgentSettingsChanged = Notification.Name("codexOAuthAgentSettingsChanged")
}

enum ZhipuAgentSettings {
    static let modelDefaultsKey = "zhipuAgentModel"
    static let baseURL = "https://open.bigmodel.cn/api/paas/v4"

    static var savedModel: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
    }

    static func load() -> OpenAICompatibleSettings? {
        let model = savedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              let endpoint = OpenAICompatibleEndpoint.normalizedURL(from: baseURL),
              let apiKey = ZhipuAgentKeychain.load()
        else { return nil }
        return OpenAICompatibleSettings(baseURL: baseURL, endpoint: endpoint, model: model, apiKey: apiKey)
    }

    static func save(model: String) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .zhipuAgentSettingsChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        ZhipuAgentKeychain.delete()
        NotificationCenter.default.post(name: .zhipuAgentSettingsChanged, object: nil)
    }
}

enum ZhipuAgentKeychain {
    private static let account = "zhipu-agent-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .zhipuAgentSettingsChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ZHIPU_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["ZAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .zhipuAgentSettingsChanged, object: nil)
    }
}

struct CodexOAuthStatus: Equatable, Sendable {
    var hasAccessToken: Bool
    var hasRefreshToken: Bool
    var accountID: String?
    var authMode: String?
    var lastRefresh: String?
    var expiresAt: Date?
    var errorMessage: String?

    var canAuthorize: Bool {
        hasAccessToken || hasRefreshToken
    }

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(5 * 60)
    }
}

enum CodexOAuthAgentSettings {
    static let modelDefaultsKey = "codexOAuthAgentModel"
    static let baseURL = "https://api.openai.com/v1"

    static var savedModel: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
    }

    static func load() -> OpenAICompatibleSettings? {
        let model = savedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = CodexOAuthStore.status()
        guard !model.isEmpty,
              let endpoint = OpenAICompatibleEndpoint.normalizedURL(from: baseURL),
              status.canAuthorize
        else { return nil }
        return OpenAICompatibleSettings(
            baseURL: baseURL,
            endpoint: endpoint,
            model: model,
            apiKey: CodexOAuthStore.cachedAccessToken() ?? ""
        )
    }

    static func save(model: String) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .codexOAuthAgentSettingsChanged, object: nil)
    }

    static func clearModel() {
        UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .codexOAuthAgentSettingsChanged, object: nil)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
