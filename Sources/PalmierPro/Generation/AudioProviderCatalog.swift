import Foundation

enum MiniMaxModelId {
    static let prefix = "minimax:"

    static func stored(_ rawId: String) -> String {
        rawId.hasPrefix(prefix) ? rawId : "\(prefix)\(rawId)"
    }

    static func raw(_ storedId: String) -> String? {
        guard storedId.hasPrefix(prefix) else { return nil }
        return String(storedId.dropFirst(prefix.count))
    }
}

@Observable
@MainActor
final class AudioProviderCatalog {
    static let shared = AudioProviderCatalog()

    private(set) var audio: [AudioModelConfig] = []
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var lastError: String?

    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .audioGenerationProviderSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshModels()
            }
        }
        Task { await refreshModels() }
    }

    func refreshModels() async {
        guard let miniMaxKey = AudioGenerationCredentialStore.load(provider: .minimax),
              !miniMaxKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            audio = []
            isLoaded = false
            isLoading = false
            lastError = nil
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let region = MiniMaxAPIRegion.stored
            let models = try await Self.fetchMiniMaxModels(apiKey: miniMaxKey, region: region)
            audio = models
            isLoaded = true
        } catch {
            audio = []
            isLoaded = false
            lastError = error.localizedDescription
        }
    }

    func miniMaxModel(rawId: String) -> AudioModelConfig? {
        audio.first { MiniMaxModelId.raw($0.id) == rawId || $0.id == rawId }
    }

    func modelExists(storedId: String) -> Bool {
        guard let raw = MiniMaxModelId.raw(storedId) else { return false }
        return audio.contains { MiniMaxModelId.raw($0.id) == raw }
    }

    private static func fetchMiniMaxModels(apiKey: String, region: MiniMaxAPIRegion) async throws -> [AudioModelConfig] {
        let object = try await AudioProviderModelProbe.fetchJSONObject(
            url: region.modelsURL,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        let rawIds = miniMaxModelIds(from: object)
        return rawIds.map(miniMaxModelConfig)
    }

    private static func miniMaxModelIds(from object: Any) -> [String] {
        let data: [Any]
        if let array = object as? [Any] {
            data = array
        } else if let dictionary = object as? [String: Any],
                  let array = dictionary["data"] as? [Any] {
            data = array
        } else {
            return []
        }

        let ids = data.compactMap { item -> String? in
            if let value = item as? String { return value }
            if let dict = item as? [String: Any] {
                return dict["id"] as? String ?? dict["model"] as? String
            }
            return nil
        }
        return Array(Set(ids.filter { $0.localizedCaseInsensitiveContains("music") })).sorted()
    }

    private static func miniMaxModelConfig(rawId: String) -> AudioModelConfig {
        let caps = AudioCaps(
            category: "music",
            voices: nil,
            defaultVoice: nil,
            supportsLyrics: true,
            supportsInstrumental: true,
            supportsStyleInstructions: false,
            durations: nil,
            minPromptLength: 10,
            inputs: ["text"],
            promptLabel: "Describe the music style or mood",
            minSeconds: nil,
            maxSeconds: nil
        )
        let entry = CatalogEntry(
            id: MiniMaxModelId.stored(rawId),
            kind: .audio,
            displayName: "MiniMax \(rawId)",
            allowedEndpoints: ["minimax"],
            responseShape: .audio,
            uiCapabilities: .audio(caps)
        )
        return AudioModelConfig(entry: entry, caps: caps)
    }
}
