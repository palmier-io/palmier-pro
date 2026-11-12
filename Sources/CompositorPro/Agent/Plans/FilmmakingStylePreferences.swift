import Foundation

/// Persistent user-authored filmmaking style preferences and reference selections.
/// Saved to `~/.compositor/style-preferences.json`, decoupled from any single project's chat.
@Observable
@MainActor
final class FilmmakingStylePreferences {
    static let shared = FilmmakingStylePreferences()

    struct PacingProfile: Codable, Sendable, Equatable {
        var targetShotDurationSeconds: Double = 3.5
        var minShotDurationSeconds: Double = 1.5
        var maxShotDurationSeconds: Double = 6.0
    }

    struct AudioProfile: Codable, Sendable, Equatable {
        var voiceTargetLUFS: Double = -16.0
        var duckingDepthDb: Double = -12.0
        var truePeakMaxDBTP: Double = -1.0
    }

    struct CaptionProfile: Codable, Sendable, Equatable {
        var captionStyle: String = "clean"
        var platform: String? = nil
        var animation: String? = nil
    }

    struct PreferencesData: Codable, Sendable, Equatable {
        var pacing: PacingProfile = .init()
        var audio: AudioProfile = .init()
        var caption: CaptionProfile = .init()
        var pinnedRecipeIds: [String] = []
        var activePlaybookId: String = "narrated-broll-playbook"
    }

    private(set) var data: PreferencesData = .init()
    private let fileURL: URL
    private static let ioQueue = DispatchQueue(label: "compositor.style-preferences", qos: .utility)

    init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".compositor/style-preferences.json")
        self.fileURL = url
        load()
    }

    func updatePacing(_ pacing: PacingProfile) {
        data.pacing = pacing
        persist()
    }

    func updateAudio(_ audio: AudioProfile) {
        data.audio = audio
        persist()
    }

    func updateCaption(_ caption: CaptionProfile) {
        data.caption = caption
        persist()
    }

    func pinRecipe(id: String) {
        guard !data.pinnedRecipeIds.contains(id) else { return }
        data.pinnedRecipeIds.append(id)
        persist()
    }

    func unpinRecipe(id: String) {
        data.pinnedRecipeIds.removeAll { $0 == id }
        persist()
    }

    func setActivePlaybook(id: String) {
        data.activePlaybookId = id
        persist()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PreferencesData.self, from: raw) else {
            return
        }
        data = decoded
    }

    private func persist() {
        let snapshot = data
        let dest = fileURL
        Self.ioQueue.async {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: dest, options: .atomic)
        }
    }
}

