import Foundation

/// Media-level group of cameras and mics from one recording session.
/// Members share a common timebase: source frame `f` of member `m` corresponds to
/// group time `m.syncOffsetFrames + f` (all in project-frame units). The timeline
/// stays flat — angle switching just rewrites a clip's mediaRef and trim.
struct MulticamGroup: Codable, Sendable, Equatable, Identifiable {
    enum Role: String, Codable, Sendable {
        /// `both` = a camera whose embedded audio is also that person's mic
        /// (each participant recorded one file, no separate mic track).
        case camera, mic, both

        var isCamera: Bool { self == .camera || self == .both }
        var isMic: Bool { self == .mic || self == .both }
    }

    struct Member: Codable, Sendable, Equatable {
        var mediaRef: String
        var role: Role
        /// Group time at which this member's source frame 0 sits (project-frame units).
        var syncOffsetFrames: Int = 0
        var speaker: String?

        init(mediaRef: String, role: Role, syncOffsetFrames: Int = 0, speaker: String? = nil) {
            self.mediaRef = mediaRef
            self.role = role
            self.syncOffsetFrames = syncOffsetFrames
            self.speaker = speaker
        }

        private enum CodingKeys: String, CodingKey {
            case mediaRef, role, syncOffsetFrames, speaker
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mediaRef = try c.decode(String.self, forKey: .mediaRef)
            role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .camera
            syncOffsetFrames = try c.decodeIfPresent(Int.self, forKey: .syncOffsetFrames) ?? 0
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        }
    }

    var id: String = UUID().uuidString
    var name: String
    var members: [Member] = []

    init(id: String = UUID().uuidString, name: String, members: [Member] = []) {
        self.id = id
        self.name = name
        self.members = members
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, members
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Multicam"
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
    }

    func member(for mediaRef: String) -> Member? {
        members.first { $0.mediaRef == mediaRef }
    }

    var cameras: [Member] { members.filter { $0.role.isCamera } }
    var mics: [Member] { members.filter { $0.role.isMic } }

    /// Camera framing `speaker`, if the group maps one.
    func camera(forSpeaker speaker: String) -> Member? {
        cameras.first { $0.speaker == speaker }
    }

    /// Source trim (project-frame units) in `to` showing the same group time
    /// that `trimStart` shows in `from`. May be negative when `to` wasn't
    /// recording yet at that moment — callers must validate.
    static func convertedTrimStart(_ trimStart: Int, from: Member, to: Member) -> Int {
        trimStart + from.syncOffsetFrames - to.syncOffsetFrames
    }
}
