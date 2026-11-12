import Foundation

/// A graphic scene whose specification is retained with the plan, so a corrected value can be
/// regenerated without reconstructing the scene by hand. `digest` and `rendererVersion` key the
/// rendered derivative: a matching digest and version means the existing media is current.
struct PlanGraphicScene: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var digest: String
    var rendererVersion: String
    /// Media asset id of the rendered derivative, once it has been installed in the package.
    var mediaRef: String?
    /// Clip id when the scene was placed on the timeline.
    var clipId: String?
    /// The authored specification receipt, stored as encoded JSON so it round-trips losslessly.
    var spec: Data

    enum CodingKeys: String, CodingKey {
        case id, kind, title, digest, rendererVersion, mediaRef, clipId, spec
    }

    init(id: String = UUID().uuidString, kind: String, title: String, digest: String,
         rendererVersion: String, mediaRef: String?, clipId: String?, spec: [String: Any]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.digest = digest
        self.rendererVersion = rendererVersion
        self.mediaRef = mediaRef
        self.clipId = clipId
        self.spec = (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])) ?? Data()
    }

    /// The authored specification as a JSON object, or empty when it was unreadable.
    var specObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: spec) as? [String: Any]) ?? [:]
    }

    var receipt: [String: Any] {
        var row: [String: Any] = [
            "id": id, "kind": kind, "title": title, "digest": digest,
            "rendererVersion": rendererVersion,
        ]
        if let mediaRef { row["mediaRef"] = mediaRef }
        if let clipId { row["clipId"] = clipId }
        return row
    }

    /// The renderer output this record describes is current for the given digest and version.
    func isCurrent(digest: String, rendererVersion: String) -> Bool {
        self.digest == digest && self.rendererVersion == rendererVersion && mediaRef != nil
    }

    static func == (lhs: PlanGraphicScene, rhs: PlanGraphicScene) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.title == rhs.title
            && lhs.digest == rhs.digest && lhs.rendererVersion == rhs.rendererVersion
            && lhs.mediaRef == rhs.mediaRef && lhs.clipId == rhs.clipId && lhs.spec == rhs.spec
    }
}