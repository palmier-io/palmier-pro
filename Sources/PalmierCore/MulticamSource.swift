import Foundation

public struct MulticamSource: Codable, Sendable, Equatable, Identifiable {
    public enum MemberKind: String, Codable, Sendable {
        case angle
        case mic
        case both
    }

    public struct SyncMap: Codable, Sendable, Equatable {
        public var offsetSeconds: Double = 0
        public var confidence: Double = 0
        public var locked: Bool = false

        public init(offsetSeconds: Double = 0, confidence: Double = 0, locked: Bool = false) {
            self.offsetSeconds = offsetSeconds
            self.confidence = confidence
            self.locked = locked
        }
    }

    public struct Member: Codable, Sendable, Equatable, Identifiable {
        public var id: String = UUID().uuidString
        public var mediaRef: String
        public var kind: MemberKind
        public var angleLabel: String
        public var sync: SyncMap = SyncMap()

        public var providesVideo: Bool { kind != .mic }
        public var providesAudio: Bool { kind != .angle }
        public var usable: Bool { sync.confidence > 0 || sync.locked }

        public init(
            id: String = UUID().uuidString,
            mediaRef: String,
            kind: MemberKind,
            angleLabel: String,
            sync: SyncMap = SyncMap()
        ) {
            self.id = id
            self.mediaRef = mediaRef
            self.kind = kind
            self.angleLabel = angleLabel
            self.sync = sync
        }
    }

    public var id: String = UUID().uuidString
    public var name: String = ""
    public var members: [Member] = []
    public var masterMemberId: String = ""

    public var master: Member? { members.first { $0.id == masterMemberId } }
    public var angles: [Member] { members.filter { $0.providesVideo && $0.usable } }
    public var mics: [Member] { members.filter { $0.providesAudio && $0.usable } }

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        members: [Member] = [],
        masterMemberId: String = ""
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.masterMemberId = masterMemberId
    }

    public func member(labeled label: String) -> Member? {
        members.first { $0.angleLabel.caseInsensitiveCompare(label) == .orderedSame }
    }

    public func member(mediaRef: String) -> Member? {
        members.first { $0.mediaRef == mediaRef }
    }
}

public extension MulticamSource.Member {
    func offsetFrames(fps: Int) -> Int {
        Int((sync.offsetSeconds * Double(fps)).rounded())
    }

    func anchorFrame(of clip: Clip, fps: Int) -> Int {
        clip.startFrame - clip.trimStartFrame - offsetFrames(fps: fps)
    }

    func coverage(sourceDuration: Double, fps: Int) -> Range<Int> {
        let start = Int((sync.offsetSeconds * Double(fps)).rounded())
        let end = Int(((sync.offsetSeconds + sourceDuration) * Double(fps)).rounded())
        return start..<max(start, end)
    }

    func trimFrame(atGroupFrame groupFrame: Int, fps: Int) -> Int {
        Int(((Double(groupFrame) / Double(fps) - sync.offsetSeconds) * Double(fps)).rounded())
    }
}
