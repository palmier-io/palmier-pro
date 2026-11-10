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
    ///
    /// Used for compositor package exports, where the manifest is the delivered package.
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

    /// Canonical source identities of the media the resolver resolved for one export.
    ///
    /// Only resolved clips count: a project manifest may hold media the export never used,
    /// and unresolved media never reached the output.
    static func sourceIds(resolver: MediaResolver, timeline: Timeline) -> Set<String> {
        let manifest = resolver.manifestSnapshot()
        let entries = manifest.entries
        var ids = Set<String>()
        for track in timeline.tracks {
            for clip in track.clips {
                guard resolver.resolveURL(for: clip.mediaRef) != nil,
                      let entry = entries.first(where: { $0.id == clip.mediaRef }) else { continue }
                ids.formUnion(VisualSourceAliases.sourceIds(
                    mediaRef: entry.id,
                    inputId: entry.inputIdentity.flatMap { $0.isValid ? $0.inputId : nil },
                    origin: entry.importInput?.origin
                ))
            }
        }
        return ids
    }

    /// Loads the bounded history from the store.
    static func load(store: UserDefaults = .standard) -> Self {
        guard let data = store.data(forKey: defaultsKey) else { return Self() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Self.self, from: data)) ?? Self()
    }

    /// Persists the bounded history to the store.
    func save(to store: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { store.set(data, forKey: Self.defaultsKey) }
    }

    /// Removes the persisted history so reads start empty.
    static func reset(store: UserDefaults = .standard) { store.removeObject(forKey: defaultsKey) }
}

extension StockDeliveryHistory: CustomStringConvertible {
    var description: String { "StockDeliveryHistory(\(entries.count) entries, \(usedSourceIds.count) sources)" }
}
