import Foundation

// Pasteboard payload for dragging an external-source card onto the timeline. Distinct from the
// library's `palmier-asset://<id>` scheme (those ids already exist); a source card isn't in the
// project yet, so this carries everything needed to materialize a downloading placeholder on drop.
struct SourceDragPayload: Codable, Sendable {
    let providerId: String
    let ref: String
    let type: String          // AssetType rawValue
    let name: String
    let durationMs: Int?

    static let scheme = "palmier-source://"

    var assetType: AssetType? { AssetType(rawValue: type) }
    var durationSeconds: Double { durationMs.map { Double($0) / 1000 } ?? 0 }

    init(card: AssetCard) {
        providerId = card.providerId
        ref = card.ref
        type = card.type.rawValue
        name = card.name
        durationMs = card.durationMs
    }

    // scheme + base64(JSON) — one line; base64 keeps refs/names free of delimiter clashes.
    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return Self.scheme }
        return Self.scheme + data.base64EncodedString()
    }

    static func isSourcePayload(_ payload: String) -> Bool { payload.contains(scheme) }

    // Decode every source line in a (possibly multi-line) pasteboard string.
    static func decodeAll(_ payload: String) -> [SourceDragPayload] {
        payload.split(separator: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix(scheme) else { return nil }
            let b64 = String(s.dropFirst(scheme.count))
            guard let data = Data(base64Encoded: b64) else { return nil }
            return try? JSONDecoder().decode(SourceDragPayload.self, from: data)
        }
    }
}
