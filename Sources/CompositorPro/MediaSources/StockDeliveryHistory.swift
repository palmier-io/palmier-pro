import Foundation

/// Bounded recent-output usage history used for cross-production novelty ranking.
///
/// Every successfully delivered export records the canonical source identities it used.
/// `find_shot_candidates` then deprioritizes sources that already appear in the history.
/// This is a ranking signal, not a ban: used sources remain eligible, and the hard
/// no-repeat rule for a single output is enforced separately by the visual-uniqueness audit.
struct StockDeliveryHistory: Sendable, Equatable, Codable {
    static let maximumEntries = 50
    static let defaultsKey = "compositor.pro.delivery-history"

    var entries: [Entry] = []

    struct Entry: Sendable, Equatable, Codable {
        var outputFilename: String
        var sourceIds: Set<String>
        var deliveredAt: Date
    }

    init(entries: [Entry] = []) { self.entries = entries }

    mutating func add(sourceIds: Set<String>, outputFilename: String) {
        entries.append(Entry(outputFilename: outputFilename, sourceIds: sourceIds, deliveredAt: .now))
        while entries.count > Self.maximumEntries { entries.removeFirst() }
    }

    var usedSourceIds: Set<String> { Set(entries.flatMap(\.sourceIds)) }

    func contains(_ sourceId: String) -> Bool { usedSourceIds.contains(sourceId) }

    /// Canonical source identities of every manifest entry.
    static func sourceIds(manifest: MediaManifest) -> Set<String> {
        var ids = Set<String>()
        for entry in manifest.entries {
            ids.formUnion(VisualSourceAliases.sourceIds(
                mediaRef: entry.id,
                inputId: entry.inputIdentity.flatMap { $0.isValid ? $0.inputId : nil },
                origin: entry.importInput?.origin
            ))
        }
        return ids
    }

    /// Loads the bounded history from the user defaults.
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return Self() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Self.self, from: data)) ?? Self()
    }

    /// Persists the bounded history to the user defaults.
    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

extension StockDeliveryHistory: CustomStringConvertible {
    var description: String { "StockDeliveryHistory(\(entries.count) entries, \(usedSourceIds.count) sources)" }
}
