import Foundation

/// Persistent, actionable editor problems that a transient toast would lose.
struct RecoveryNotice: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case missingMedia
        case unreadablePlans
        case projectFolderMissing
    }

    let kind: Kind
    let message: String

    var id: String { kind.rawValue }
}

enum RecoveryNoticeBuilder {
    static func notices(
        missingMediaCount: Int,
        plansUnreadable: Bool,
        projectFolderMissing: Bool,
        localize: ((String) -> String)? = nil
    ) -> [RecoveryNotice] {
        func text(_ value: String) -> String { localize?(value) ?? value }
        var notices: [RecoveryNotice] = []
        if projectFolderMissing {
            notices.append(RecoveryNotice(
                kind: .projectFolderMissing,
                message: text("This project's folder is unreachable. Save a copy before editing further.")
            ))
        }
        if missingMediaCount > 0 {
            let noun = missingMediaCount == 1 ? "clip is missing media" : "clips are missing media"
            notices.append(RecoveryNotice(
                kind: .missingMedia,
                message: text("\(missingMediaCount) \(noun). Relink the source folder to restore previews and export.")
            ))
        }
        if plansUnreadable {
            notices.append(RecoveryNotice(
                kind: .unreadablePlans,
                message: text("The saved edit plans could not be read and were left untouched.")
            ))
        }
        return notices
    }
}

extension RecoveryNoticeBuilder {
    /// Cheap existence probe for the open package; run off the main actor.
    @concurrent
    static func folderMissing(_ url: URL?) async -> Bool {
        guard let url else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
