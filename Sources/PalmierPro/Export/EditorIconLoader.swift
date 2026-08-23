import Foundation

enum ExportEditorApplication: String, Identifiable, Sendable {
    case premierePro = "Premiere Pro"
    case davinciResolve = "DaVinci Resolve"
    case finalCutPro = "Final Cut Pro"

    var id: Self { self }
    var displayName: String { rawValue }
}

enum EditorIconLoader {
    private struct ApplicationBundleInfo: Decodable {
        let bundleIdentifier: String
        let iconFile: String?

        enum CodingKeys: String, CodingKey {
            case bundleIdentifier = "CFBundleIdentifier"
            case iconFile = "CFBundleIconFile"
        }
    }

    @concurrent
    static func loadIconData(
        searchDirectories: [URL]? = nil
    ) async -> [ExportEditorApplication: Data] {
        let fileManager = FileManager.default
        let roots = searchDirectories ?? [
            FileManager.SearchPathDomainMask.localDomainMask,
            .userDomainMask,
        ].compactMap {
            fileManager.urls(for: .applicationDirectory, in: $0).first
        }
        let rootEntries = roots.flatMap { contents(of: $0, fileManager: fileManager) }
        let nestedEntries = rootEntries
            .filter {
                guard $0.pathExtension.lowercased() != "app",
                      let values = try? $0.resourceValues(
                          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                      ) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .flatMap { contents(of: $0, fileManager: fileManager) }

        var icons: [ExportEditorApplication: Data] = [:]
        for applicationURL in (rootEntries + nestedEntries)
            where applicationURL.pathExtension.lowercased() == "app" {
            let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
            guard let infoData = try? Data(
                contentsOf: contentsURL.appendingPathComponent("Info.plist")
            ),
            let info = try? PropertyListDecoder().decode(ApplicationBundleInfo.self, from: infoData),
            let editor = editor(forBundleIdentifier: info.bundleIdentifier),
            icons[editor] == nil,
            let iconFile = info.iconFile, !iconFile.isEmpty else { continue }

            let iconURL = contentsURL.appendingPathComponent("Resources/\(iconFile)")
            let candidates = iconURL.pathExtension.isEmpty
                ? [iconURL, iconURL.appendingPathExtension("icns")]
                : [iconURL]
            if let data = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first {
                icons[editor] = data
            }
        }
        return icons
    }

    static func editor(forBundleIdentifier bundleIdentifier: String) -> ExportEditorApplication? {
        if bundleIdentifier.hasPrefix("com.adobe.PremierePro") { return .premierePro }
        if bundleIdentifier == "com.blackmagic-design.DaVinciResolve" { return .davinciResolve }
        if bundleIdentifier.hasPrefix("com.apple.FinalCut") { return .finalCutPro }
        return nil
    }

    private static func contents(of url: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
