import Foundation

struct MulticamSource: Codable, Sendable, Equatable, Identifiable {
    enum MemberKind: String, Codable, Sendable {
        case angle
        case mic
        case both
    }

    struct SyncMap: Codable, Sendable, Equatable {
        var offsetSeconds: Double = 0
        var confidence: Double = 0
        var locked: Bool = false
    }

    struct Member: Codable, Sendable, Equatable, Identifiable {
        var id: String = UUID().uuidString
        var mediaRef: String
        var kind: MemberKind
        var angleLabel: String
        var sync: SyncMap = SyncMap()

        var providesVideo: Bool { kind != .mic }
        var providesAudio: Bool { kind != .angle }
        var usable: Bool { sync.confidence > 0 || sync.locked }
    }

    var id: String = UUID().uuidString
    var name: String = ""
    var members: [Member] = []
    var masterMemberId: String = ""

    var master: Member? { members.first { $0.id == masterMemberId } }
    var angles: [Member] { members.filter { $0.providesVideo && $0.usable } }
    var mics: [Member] { members.filter { $0.providesAudio && $0.usable } }

    func member(labeled label: String) -> Member? {
        members.first { $0.angleLabel.caseInsensitiveCompare(label) == .orderedSame }
    }

    func member(mediaRef: String) -> Member? {
        members.first { $0.mediaRef == mediaRef }
    }
}

extension MulticamSource.Member {
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
