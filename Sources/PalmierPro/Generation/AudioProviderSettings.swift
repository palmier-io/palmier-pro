import Foundation

extension Notification.Name {
    static let audioGenerationProviderSettingsChanged = Notification.Name("audioGenerationProviderSettingsChanged")
}

enum AudioGenerationCredentialProvider: String, CaseIterable, Identifiable, Equatable {
    case elevenLabs
    case googleAI
    case minimax
    case sonilo
    case mirelo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .googleAI: "Google AI"
        case .minimax: "MiniMax"
        case .sonilo: "Sonilo"
        case .mirelo: "Mirelo"
        }
    }

    var subtitle: String {
        switch self {
        case .elevenLabs:
            "Speech and music model access. The key is stored in your macOS Keychain."
        case .googleAI:
            "Gemini and Lyria model access. The key is stored in your macOS Keychain."
        case .minimax:
            "Music model access. Choose the API region that issued the key."
        case .sonilo:
            "Video-to-music model access. The key is stored in your macOS Keychain."
        case .mirelo:
            "Video-to-sound-effect model access. The key is stored in your macOS Keychain."
        }
    }

    var placeholder: String { "API key" }

    var keychainAccount: String { "audio-generation-\(rawValue)-api-key" }

    var docsURL: URL? {
        switch self {
        case .elevenLabs: URL(string: "https://elevenlabs.io/docs/api-reference/models")
        case .googleAI: URL(string: "https://ai.google.dev/api/models")
        case .minimax: MiniMaxAPIRegion.stored.docsURL
        case .sonilo: URL(string: "https://platform.sonilo.com/")
        case .mirelo: URL(string: "https://mirelo.ai/api-docs")
        }
    }
}

enum MiniMaxAPIRegion: String, CaseIterable, Identifiable {
    case mainlandChina
    case global

    private static let defaultsKey = "audioGenerationMiniMaxAPIRegion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainlandChina: "Mainland China"
        case .global: "International"
        }
    }

    var modelsURL: URL {
        switch self {
        case .mainlandChina: URL(string: "https://api.minimaxi.com/v1/models")!
        case .global: URL(string: "https://api.minimax.io/v1/models")!
        }
    }

    var musicGenerationURL: URL {
        switch self {
        case .mainlandChina: URL(string: "https://api.minimaxi.com/v1/music_generation")!
        case .global: URL(string: "https://api.minimax.io/v1/music_generation")!
        }
    }

    var docsURL: URL {
        switch self {
        case .mainlandChina: URL(string: "https://platform.minimaxi.com/docs/api-reference/models/openai/list-models")!
        case .global: URL(string: "https://platform.minimax.io/docs/api-reference/models/openai/list-models")!
        }
    }

    static var stored: MiniMaxAPIRegion {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let region = MiniMaxAPIRegion(rawValue: raw)
        else { return .mainlandChina }
        return region
    }

    static func save(_ region: MiniMaxAPIRegion) {
        UserDefaults.standard.set(region.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: .audioGenerationProviderSettingsChanged, object: nil)
    }
}

enum AudioGenerationCredentialStore {
    static func save(_ key: String, provider: AudioGenerationCredentialProvider) {
        KeychainStore.save(key, account: provider.keychainAccount)
        NotificationCenter.default.post(name: .audioGenerationProviderSettingsChanged, object: nil)
    }

    static func load(provider: AudioGenerationCredentialProvider) -> String? {
        KeychainStore.load(account: provider.keychainAccount)
    }

    static func delete(provider: AudioGenerationCredentialProvider) {
        KeychainStore.delete(account: provider.keychainAccount)
        NotificationCenter.default.post(name: .audioGenerationProviderSettingsChanged, object: nil)
    }
}

struct AudioProviderModelProbeResult: Sendable {
    let count: Int?
}

enum AudioProviderModelProbeError: LocalizedError {
    case transport(String)
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .transport(let message): message
        case .api(_, let message): message
        }
    }
}

enum AudioProviderModelProbe {
    static func fetch(
        provider: AudioGenerationCredentialProvider,
        apiKey: String,
        miniMaxRegion: MiniMaxAPIRegion = MiniMaxAPIRegion.stored
    ) async throws -> AudioProviderModelProbeResult {
        switch provider {
        case .elevenLabs:
            return try await fetchJSONCount(
                url: URL(string: "https://api.elevenlabs.io/v1/models")!,
                headers: ["xi-api-key": apiKey],
                arrayKey: nil
            )
        case .googleAI:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            return try await fetchJSONCount(url: components.url!, headers: [:], arrayKey: "models")
        case .minimax:
            return try await fetchJSONCount(
                url: miniMaxRegion.modelsURL,
                headers: ["Authorization": "Bearer \(apiKey)"],
                arrayKey: "data"
            )
        case .sonilo, .mirelo:
            return AudioProviderModelProbeResult(count: nil)
        }
    }

    static func fetchJSONCount(url: URL, headers: [String: String], arrayKey: String?) async throws -> AudioProviderModelProbeResult {
        let object = try await fetchJSONObject(url: url, headers: headers)
        if let array = object as? [Any] {
            return AudioProviderModelProbeResult(count: array.count)
        }
        if let arrayKey,
           let dictionary = object as? [String: Any],
           let array = dictionary[arrayKey] as? [Any] {
            return AudioProviderModelProbeResult(count: array.count)
        }
        return AudioProviderModelProbeResult(count: nil)
    }

    static func fetchJSONObject(url: URL, headers: [String: String]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudioProviderModelProbeError.transport("Non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AudioProviderModelProbeError.api(status: http.statusCode, message: detail)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
