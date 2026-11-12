import Foundation

extension Notification.Name {
    /// Posted by Settings after the custom model list changes. The agent service is owned per
    /// editor, so it cannot be called directly from the settings pane.
    static let agentCustomEndpointChanged = Notification.Name("agentCustomEndpointChanged")
}

/// A user-supplied OpenAI-compatible chat model. The agent speaks `/chat/completions` to it,
/// which is the dialect Ollama, LM Studio, vLLM, LiteLLM, OpenRouter, Groq and most gateways
/// implement. Each carries its own endpoint and credential, so several can coexist — a local
/// model and a hosted gateway, or two models behind one gateway.
struct CustomAgentModel: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    /// Shown in the model picker. Falls back to the wire model id when blank.
    var name: String
    /// Base URL including the version segment, e.g. `http://localhost:11434/v1`.
    var baseURL: URL
    /// Wire model identifier, e.g. `qwen3-coder:30b` or `anthropic/claude-sonnet-5`.
    var modelID: String
    // Nil leaves image support undeclared; the endpoint must accept or reject image requests.
    var supportsImages: Bool?

    init(id: UUID = UUID(), name: String = "", baseURL: URL, modelID: String, supportsImages: Bool? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelID = modelID
        self.supportsImages = supportsImages
    }

    var chatCompletionsURL: URL { baseURL.appending(path: "chat/completions") }

    /// Loopback servers (Ollama, LM Studio) need no credential; anything remote must present a key.
    var allowsMissingAPIKey: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }

    /// The model identity, which is also what the request sends. `name` is only a nickname, so
    /// showing it as the title made every model on one gateway look identical in the picker.
    var displayTitle: String { modelID.isEmpty ? name : modelID }

    /// The nickname, when it adds something the model id does not already say.
    var displaySubtitle: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == modelID ? nil : trimmed
    }
}

enum CustomModelSaveResult: Equatable {
    case saved(UUID)
    case failed(String)
}

/// What saving a model should do to its credential. An untouched key field must be
/// `unchanged` rather than an empty string, or opening a model and saving it without editing
/// the field would silently destroy the stored key.
enum CustomKeyUpdate: Equatable {
    case unchanged
    case set(String)
    case clear
}

enum CustomModelStore {
    private static let listKey = "agentCustomModels"
    private static let selectedKey = "agentCustomModelSelected"

    static func load(defaults: UserDefaults = .standard) -> [CustomAgentModel] {
        guard let data = defaults.data(forKey: listKey),
              let models = try? JSONDecoder().decode([CustomAgentModel].self, from: data)
        else { return [] }
        return models
    }

    private static func persist(_ models: [CustomAgentModel], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: listKey)
    }

    static func selectedID(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
    }

    static func setSelectedID(_ id: UUID?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id.uuidString, forKey: selectedKey)
        } else {
            defaults.removeObject(forKey: selectedKey)
        }
    }

    /// The selected model, or nil when the selection points at a removed model.
    static func selected(defaults: UserDefaults = .standard) -> CustomAgentModel? {
        let models = load(defaults: defaults)
        guard let id = selectedID(defaults: defaults) else { return models.first }
        return models.first { $0.id == id } ?? models.first
    }

    /// Adds or updates a model, returning its id or the validation failure.
    @MainActor
    static func upsert(
        id: UUID?,
        name: String,
        baseURL rawBase: String,
        modelID rawModelID: String,
        supportsImages: Bool? = nil,
        defaults: UserDefaults = .standard
    ) -> CustomModelSaveResult {
        let base = rawBase.trimmingCharacters(in: .whitespaces)
        let modelID = rawModelID.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let url = normalizedBaseURL(base) else {
            return .failed(L10n.string("Enter a valid http:// or https:// base URL."))
        }
        guard !modelID.isEmpty else { return .failed(L10n.string("Enter a model identifier.")) }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let model = CustomAgentModel(
            id: id ?? UUID(),
            name: trimmedName,
            baseURL: url,
            modelID: modelID,
            supportsImages: supportsImages
        )
        var models = load(defaults: defaults)
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index] = model
        } else {
            models.append(model)
        }
        persist(models, defaults: defaults)
        if selectedID(defaults: defaults) == nil { setSelectedID(model.id, defaults: defaults) }
        return .saved(model.id)
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        let models = load(defaults: defaults).filter { $0.id != id }
        persist(models, defaults: defaults)
        if selectedID(defaults: defaults) == id { setSelectedID(models.first?.id, defaults: defaults) }
    }

    /// Persists the model and its credential as one operation, and resolves only once both are
    /// stored. The key travels as a value: when a caller cleared the form after saving, a
    /// detached write that read the field would store the emptied value and delete the key it
    /// had just been given. Resolving after the write also lets the caller announce the change
    /// only once the credential is readable, so nothing caches an empty key.
    @MainActor
    static func upsert(
        id: UUID?,
        name: String,
        baseURL: String,
        modelID: String,
        key: CustomKeyUpdate,
        supportsImages: Bool? = nil,
        defaults: UserDefaults = .standard
    ) async -> CustomModelSaveResult {
        let result = upsert(
            id: id, name: name, baseURL: baseURL, modelID: modelID,
            supportsImages: supportsImages, defaults: defaults
        )
        guard case .saved(let savedID) = result else { return result }
        switch key {
        case .unchanged:
            break
        case .set(let value):
            await setKey(value, for: savedID)
        case .clear:
            await setKey(nil, for: savedID)
        }
        return result
    }

    // MARK: - Credentials

    /// One Keychain account per model, so two models on the same host can differ.
    static func keyAccount(for id: UUID) -> String { "custom-agent-api-key.\(id.uuidString)" }

    static func loadKey(for id: UUID) async -> String {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                continuation.resume(returning: KeychainStore.load(account: keyAccount(for: id)) ?? "")
            }
        }
    }

    static func setKey(_ key: String?, for id: UUID) async {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                if let key {
                    KeychainStore.save(key, account: keyAccount(for: id))
                } else {
                    KeychainStore.delete(account: keyAccount(for: id))
                }
                continuation.resume(returning: ())
            }
        }
    }

    /// Accepts a base with or without the version segment and strips a trailing slash, so
    /// `localhost:11434`, `localhost:11434/`, and `localhost:11434/v1` all mean the same thing.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        guard url.path.isEmpty || url.path == "/" else { return url }
        return url.appending(path: "v1")
    }
}
