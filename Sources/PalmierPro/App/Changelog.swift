import Foundation

struct ChangelogFeed: Decodable {
    let changelogURL: String?
    let entries: [ChangelogEntry]
}

struct ChangelogEntry: Decodable, Identifiable {
    let version: String
    let date: String?
    let sections: [ChangelogSection]

    var id: String { version }
}

struct ChangelogSection: Decodable {
    let heading: String?
    let items: [String]
}

@MainActor @Observable
final class ChangelogStore {
    static let shared = ChangelogStore()

    private(set) var pending: ChangelogEntry?
    private(set) var changelogURL: URL?

    private let lastSeenKey = "lastSeenVersion"

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Show the overlay only on a genuine version change, never on a fresh install
    func checkForWhatsNew() {
        guard let feed = loadFeed() else { return }
        changelogURL = feed.changelogURL.flatMap { URL(string: $0) }

        let current = currentVersion
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenKey)
        UserDefaults.standard.set(current, forKey: lastSeenKey)

        guard let lastSeen, !lastSeen.isEmpty, lastSeen != current else { return }
        pending = feed.entries.first { $0.version == current }
    }

    func dismiss() {
        pending = nil
    }

    private func loadFeed() -> ChangelogFeed? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Changelog/changelog.json"),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Changelog/changelog.json"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            return try? JSONDecoder().decode(ChangelogFeed.self, from: data)
        }
        return nil
    }
}
