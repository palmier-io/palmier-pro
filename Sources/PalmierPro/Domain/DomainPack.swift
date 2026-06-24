import Foundation

/// A domain editorial pack: per-moment guidance + ordered ceremony templates, compiled
/// from the reference dataset by scripts/build_domain_pack.py and bundled as a resource.
struct DomainPack: Decodable, Sendable {
    let domain: String
    let culture: String?
    let audioPatterns: String?
    let typicalPacing: String?
    let moments: [String: Moment]
    let ceremonies: [String: [String]]
    let learnedSequences: LearnedSequences?

    struct LearnedSequences: Decodable, Sendable {
        let videosAnalyzed: Int?
        let openingMoments: [MomentFraction]?
        let commonNext: [String: [MomentFraction]]?
        let note: String?
    }

    struct MomentFraction: Decodable, Sendable {
        let moment: String
        let fraction: Double
    }

    struct Moment: Decodable, Sendable {
        let category: String
        let importance: String          // core | optional | filler
        let audioPolicy: String         // feature-original | music-bed-ok | ambient
        let preferredShots: [String]
        let avoidQualities: [String]
        let classificationCues: String
        let referenceCount: Int?
        let typicalDurationSec: Int?
    }

    /// Ordered moment slots for a ceremony, or nil if the ceremony is unknown.
    func ceremony(_ name: String) -> [String]? {
        ceremonies[name.lowercased()]
    }

    func moment(_ name: String) -> Moment? {
        moments[name]
    }

    var ceremonyNames: [String] { ceremonies.keys.sorted() }
    var momentNames: [String] { moments.keys.sorted() }
}

enum DomainPackStore {
    @MainActor private static var cache: [String: DomainPack] = [:]

    /// Loads a bundled domain pack (e.g. "malay_wedding"), or nil if absent/unparseable.
    @MainActor
    static func load(_ domain: String) -> DomainPack? {
        if let hit = cache[domain] { return hit }
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("DomainPacks/\(domain).json"),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/DomainPacks/\(domain).json"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let pack = try? JSONDecoder().decode(DomainPack.self, from: data) else { continue }
            cache[domain] = pack
            return pack
        }
        return nil
    }
}
