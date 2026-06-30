import Foundation

extension Notification.Name {
    static let captionTranscriptionProviderChanged = Notification.Name("captionTranscriptionProviderChanged")
    static let volcengineSpeechSettingsChanged = Notification.Name("volcengineSpeechSettingsChanged")
}

enum CaptionTranscriptionProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case local
    case volcengine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "Local"
        case .volcengine: "Volcengine"
        }
    }
}

enum CaptionTranscriptionProviderPreference {
    private static let defaultsKey = "captionTranscriptionProvider"

    static var stored: CaptionTranscriptionProvider {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let provider = CaptionTranscriptionProvider(rawValue: raw)
        else { return .local }
        return provider
    }

    static func save(_ provider: CaptionTranscriptionProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: .captionTranscriptionProviderChanged, object: nil)
    }
}

struct VolcengineSpeechSettings: Equatable, Sendable {
    static let endpointDefaultsKey = "volcengineSpeechEndpoint"
    static let resourceIDDefaultsKey = "volcengineSpeechResourceID"
    static let defaultEndpointString = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
    static let defaultResourceID = "volc.seedasr.auc_turbo"

    let endpointString: String
    let endpoint: URL
    let resourceID: String
    let apiKey: String

    var hasAPIKey: Bool { !apiKey.isEmpty }
    var isAvailable: Bool { hasAPIKey && !resourceID.isEmpty }

    static func load() -> VolcengineSpeechSettings? {
        let endpointString = configuredEndpointString
        guard let endpoint = URL(string: endpointString),
              endpoint.scheme != nil,
              endpoint.host != nil else { return nil }
        return VolcengineSpeechSettings(
            endpointString: endpointString,
            endpoint: endpoint,
            resourceID: configuredResourceID,
            apiKey: VolcengineSpeechKeychain.load() ?? ""
        )
    }

    static var savedEndpointString: String {
        UserDefaults.standard.string(forKey: endpointDefaultsKey) ?? defaultEndpointString
    }

    static var savedResourceID: String {
        UserDefaults.standard.string(forKey: resourceIDDefaultsKey) ?? defaultResourceID
    }

    static func save(endpointString: String = savedEndpointString, resourceID: String = savedResourceID) {
        UserDefaults.standard.set(endpointString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointDefaultsKey)
        UserDefaults.standard.set(resourceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: resourceIDDefaultsKey)
        NotificationCenter.default.post(name: .volcengineSpeechSettingsChanged, object: nil)
    }

    static func resetServiceDefaults() {
        UserDefaults.standard.removeObject(forKey: endpointDefaultsKey)
        UserDefaults.standard.removeObject(forKey: resourceIDDefaultsKey)
        NotificationCenter.default.post(name: .volcengineSpeechSettingsChanged, object: nil)
    }

    private static var configuredEndpointString: String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["VOLCENGINE_SPEECH_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return savedEndpointString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var configuredResourceID: String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["VOLCENGINE_SPEECH_RESOURCE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return savedResourceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum VolcengineSpeechKeychain {
    private static let account = "volcengine-speech-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .volcengineSpeechSettingsChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["VOLCENGINE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["ARK_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .volcengineSpeechSettingsChanged, object: nil)
    }
}

enum VolcengineSpeechAvailability {
    static var canExposeCaptionAlignment: Bool {
        VolcengineSpeechSettings.load()?.isAvailable == true
    }
}
