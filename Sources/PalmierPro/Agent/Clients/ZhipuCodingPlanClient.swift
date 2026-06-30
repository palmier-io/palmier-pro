import Foundation

extension Notification.Name {
    static let zhipuCodingPlanSettingsChanged = Notification.Name("zhipuCodingPlanSettingsChanged")
}

enum ZhipuCodingPlanModel: String, CaseIterable, Identifiable, Sendable {
    case glm52 = "glm-5.2"
    case glm5Turbo = "glm-5-turbo"
    case glm47 = "glm-4.7"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

struct ZhipuCodingPlanSettings: Equatable, Sendable {
    static let modelDefaultsKey = "zhipuCodingPlanModel"
    static let baseURL = "https://api.z.ai/api/coding/paas/v4"
    static let endpoint = URL(string: "https://api.z.ai/api/coding/paas/v4/chat/completions")!
    static let defaultModel = ZhipuCodingPlanModel.glm52.rawValue

    let model: String
    let apiKey: String

    var hasAPIKey: Bool { !apiKey.isEmpty }

    var openAICompatibleSettings: OpenAICompatibleSettings {
        OpenAICompatibleSettings(
            baseURL: Self.baseURL,
            endpoint: Self.endpoint,
            model: model,
            apiKey: apiKey
        )
    }

    static func load() -> ZhipuCodingPlanSettings {
        ZhipuCodingPlanSettings(
            model: savedModel,
            apiKey: ZhipuCodingPlanKeychain.load() ?? ""
        )
    }

    static var savedModel: String {
        let raw = UserDefaults.standard.string(forKey: modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ZhipuCodingPlanModel(rawValue: raw) != nil { return raw }
        return defaultModel
    }

    static func save(model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? defaultModel : trimmed, forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .zhipuCodingPlanSettingsChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        ZhipuCodingPlanKeychain.delete()
        NotificationCenter.default.post(name: .zhipuCodingPlanSettingsChanged, object: nil)
    }
}

enum ZhipuCodingPlanKeychain {
    private static let account = "zhipu-coding-plan-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .zhipuCodingPlanSettingsChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ZAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["ZHIPU_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .zhipuCodingPlanSettingsChanged, object: nil)
    }
}
