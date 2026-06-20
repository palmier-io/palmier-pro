import Foundation
import Observation

struct LUTEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let url: URL
}

/// A user-chosen folder of `.cube` LUTs, scanned in place and remembered across launches.
@MainActor
@Observable
final class LUTLibrary {
    static let shared = LUTLibrary()
    private let defaultsKey = "lutLibraryFolderPath"

    private(set) var folderURL: URL?
    private(set) var groups: [(category: String, luts: [LUTEntry])] = []

    var isConfigured: Bool { folderURL != nil && !groups.isEmpty }
    var folderName: String { folderURL?.lastPathComponent ?? "Browse…" }

    init() {
        if let path = UserDefaults.standard.string(forKey: defaultsKey) {
            folderURL = URL(fileURLWithPath: path)
            rescan()
        }
    }

    func setFolder(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
        rescan()
    }

    func clear() {
        folderURL = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        groups = []
    }

    /// Picker default — offered only if it exists on disk.
    static var suggestedFolder: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func rescan() {
        guard let root = folderURL else { groups = []; return }
        var byCategory: [String: [LUTEntry]] = [:]
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "cube" {
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let category = rel.contains("/") ? String(rel.prefix(while: { $0 != "/" })) : root.lastPathComponent
                byCategory[category, default: []].append(
                    LUTEntry(id: url.path, name: url.deletingPathExtension().lastPathComponent,
                             category: category, url: url)
                )
            }
        }
        groups = byCategory
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }
}
