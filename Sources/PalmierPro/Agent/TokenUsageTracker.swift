import Foundation

/// A single agent request's token usage, tagged with the actual model that ran.
/// For OpenRouter this is the full slug (e.g. `anthropic/claude-sonnet-4.5`), so
/// usage is always attributed to the model selected at request time.
struct TokenUsageRecord: Codable, Sendable, Identifiable {
    var id = UUID()
    var date = Date()
    let provider: String
    let model: String
    var providerMode: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

/// Persistent, append-only record of agent token usage. Aggregation and credit
/// mapping are intentionally left to callers — this only captures the raw counts.
@Observable
@MainActor
final class TokenUsageTracker {
    static let shared = TokenUsageTracker()

    private(set) var records: [TokenUsageRecord] = []

    private static let storeURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/token-usage.json", isDirectory: false)

    /// Stable per-install id, used to attribute usage to a device in the dashboard.
    static let deviceId: String = {
        let key = "kawenreelDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    init() { load() }

    func record(model: String, provider: AgentProvider, providerMode: AgentProviderMode, usage: AgentTokenUsage) {
        guard !usage.isEmpty else { return }
        let record = TokenUsageRecord(
            provider: provider.rawValue,
            model: model,
            providerMode: providerMode.rawValue,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens
        )
        records.append(record)
        save()
    }

    // MARK: Aggregates

    var totalTokens: Int { records.reduce(0) { $0 + $1.totalTokens } }

    func totalTokens(forModel model: String) -> Int {
        records.lazy.filter { $0.model == model }.reduce(0) { $0 + $1.totalTokens }
    }

    /// Lifetime token totals keyed by model identifier.
    func totalsByModel() -> [String: Int] {
        records.reduce(into: [:]) { $0[$1.model, default: 0] += $1.totalTokens }
    }

    func reset() {
        records.removeAll()
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([TokenUsageRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        let snapshot = records
        let url = Self.storeURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }
}
