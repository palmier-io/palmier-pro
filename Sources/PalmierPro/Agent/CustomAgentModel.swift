import Foundation
import Observation

struct CustomAgentModel: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var provider: AgentProvider
    var modelID: String
    var displayName: String

    var persistenceKey: String { "custom.\(id.uuidString)" }

    init(
        id: UUID = UUID(),
        provider: AgentProvider,
        modelID: String,
        displayName: String
    ) {
        self.id = id
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName
    }
}

struct AgentChatModel: Hashable, Sendable, Identifiable {
    enum Source: Hashable, Sendable {
        case builtIn(AgentModel)
        case custom(CustomAgentModel)
    }

    let source: Source

    static func builtIn(_ model: AgentModel) -> AgentChatModel {
        AgentChatModel(source: .builtIn(model))
    }

    static func custom(_ model: CustomAgentModel) -> AgentChatModel {
        AgentChatModel(source: .custom(model))
    }

    static var builtIns: [AgentChatModel] {
        AgentModel.allCases.map(builtIn)
    }

    static let defaultModel = builtIn(.defaultModel)

    var id: String {
        switch source {
        case .builtIn(let model): model.rawValue
        case .custom(let model): model.persistenceKey
        }
    }

    var persistenceToken: String { id }

    var apiModelID: String {
        switch source {
        case .builtIn(let model): model.rawValue
        case .custom(let model): model.modelID
        }
    }

    var displayName: String {
        switch source {
        case .builtIn(let model): model.displayName
        case .custom(let model): model.displayName
        }
    }

    var provider: AgentProvider {
        switch source {
        case .builtIn(let model): model.provider
        case .custom(let model): model.provider
        }
    }

    var maxOutputTokens: Int { 64_000 }

    var requiresPaidHostedPlan: Bool {
        switch source {
        case .builtIn(let model): model.requiresPaidHostedPlan
        case .custom: false
        }
    }

    var isCustom: Bool {
        if case .custom = source { return true }
        return false
    }

    var supportedReasoningEfforts: [AgentReasoningEffort] {
        switch provider {
        case .anthropic:
            [.low, .medium, .high, .xHigh, .max]
        case .openAI:
            AgentReasoningEffort.allCases
        }
    }

    static func resolve(
        persistenceToken: String,
        customs: [CustomAgentModel]
    ) -> AgentChatModel? {
        if let builtIn = AgentModel.persisted(persistenceToken) {
            return .builtIn(builtIn)
        }
        guard persistenceToken.hasPrefix("custom.") else { return nil }
        let rawID = String(persistenceToken.dropFirst("custom.".count))
        guard let uuid = UUID(uuidString: rawID),
              let custom = customs.first(where: { $0.id == uuid })
        else { return nil }
        return .custom(custom)
    }
}

extension AgentChatModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case custom
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            if let builtIn = AgentModel.persisted(raw) {
                source = .builtIn(builtIn)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unknown agent model \(raw)"
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = .custom(try container.decode(CustomAgentModel.self, forKey: .custom))
    }

    func encode(to encoder: Encoder) throws {
        switch source {
        case .builtIn(let model):
            var single = encoder.singleValueContainer()
            try single.encode(model.rawValue)
        case .custom(let model):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .custom)
        }
    }
}

extension Notification.Name {
    static let customAgentModelsChanged = Notification.Name("customAgentModelsChanged")
}

@Observable
@MainActor
final class CustomAgentModelStore {
    static let shared = CustomAgentModelStore()

    private static let defaultsKey = "customAgentModels"
    private let defaults: UserDefaults

    private(set) var models: [CustomAgentModel]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.models = Self.load(from: defaults)
    }

    @discardableResult
    func add(
        provider: AgentProvider,
        modelID: String,
        displayName: String
    ) throws -> CustomAgentModel {
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw CustomAgentModelError.emptyModelID
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? trimmedID : trimmedName
        if models.contains(where: {
            $0.provider == provider && $0.modelID.caseInsensitiveCompare(trimmedID) == .orderedSame
        }) {
            throw CustomAgentModelError.duplicateModelID
        }
        if AgentModel.allCases.contains(where: {
            $0.provider == provider && $0.rawValue.caseInsensitiveCompare(trimmedID) == .orderedSame
        }) {
            throw CustomAgentModelError.duplicatesBuiltIn
        }

        let model = CustomAgentModel(provider: provider, modelID: trimmedID, displayName: name)
        models.append(model)
        models.sort { lhs, rhs in
            if lhs.provider != rhs.provider {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        persist()
        return model
    }

    func remove(id: UUID) {
        models.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(models)
            defaults.set(data, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: .customAgentModelsChanged, object: nil)
        } catch {
            Log.agent.error("custom agent model persist failed: \(error.localizedDescription)")
        }
    }

    private static func load(from defaults: UserDefaults) -> [CustomAgentModel] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([CustomAgentModel].self, from: data)
        } catch {
            Log.agent.error("custom agent model load failed: \(error.localizedDescription)")
            return []
        }
    }
}

enum CustomAgentModelError: LocalizedError {
    case emptyModelID
    case duplicateModelID
    case duplicatesBuiltIn

    var errorDescription: String? {
        switch self {
        case .emptyModelID:
            "Enter a model ID."
        case .duplicateModelID:
            "A custom model with this ID already exists."
        case .duplicatesBuiltIn:
            "That model ID is already built in."
        }
    }
}
