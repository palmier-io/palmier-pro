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
    var accountID: String?
    var authMode: String?
    var lastRefresh: String?
}

enum CodexOAuthAgentSettings {
    static let modelDefaultsKey = "codexOAuthAgentModel"
    static let baseURL = "https://api.openai.com/v1"

    static var savedModel: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
    }

    static func load() -> OpenAICompatibleSettings? {
        let model = savedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              let endpoint = OpenAICompatibleEndpoint.normalizedURL(from: baseURL),
              let accessToken = CodexOAuthStore.accessToken()
        else { return nil }
        return OpenAICompatibleSettings(baseURL: baseURL, endpoint: endpoint, model: model, apiKey: accessToken)
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

enum CodexOAuthStore {
    private static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    static func accessToken() -> String? {
        loadAuthFile()?.tokens?.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func status() -> CodexOAuthStatus {
        guard let file = loadAuthFile() else {
            return CodexOAuthStatus(hasAccessToken: false, accountID: nil, authMode: nil, lastRefresh: nil)
        }
        return CodexOAuthStatus(
            hasAccessToken: file.tokens?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            accountID: file.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            authMode: file.authMode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            lastRefresh: file.lastRefresh?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private static func loadAuthFile() -> CodexAuthFile? {
        guard let data = try? Data(contentsOf: authFileURL) else { return nil }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    private struct CodexAuthFile: Decodable {
        let authMode: String?
        let lastRefresh: String?
        let tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case lastRefresh = "last_refresh"
            case tokens
        }
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
