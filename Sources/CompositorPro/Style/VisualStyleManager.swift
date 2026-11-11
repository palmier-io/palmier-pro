import Foundation

/// Loads `VisualStyle` playbooks from bundled JSON resources and from
/// user-provided files on disk.
///
/// Bundled styles live in `Resources/Styles/` and are copied into the app
/// bundle by `Package.swift`. User styles can be dropped into
/// `~/Library/Application Support/Compositor Pro/Styles/` (or any directory
/// the caller points at).
///
/// Style lookup is case-insensitive by stem name. A bundled preset always
/// wins over a user style with the same name.
enum VisualStyleManager {

    /// Directory of user-installed styles, outside the app bundle.
    static let userStylesDirectory: URL? = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Compositor Pro/Styles", isDirectory: true)
    }()

    /// Bundled preset style names shipped with the app.
    static let bundledNames: [String] = [
        "premium-minimalist",
        "anime-ghibli",
    ]

    /// Loads a style by name. Bundled presets take precedence over user styles.
    static func load(named name: String) -> VisualStyle? {
        if let bundled = loadBundled(named: name) { return bundled }
        if let user = loadUser(named: name) { return user }
        return nil
    }

    /// All available style names (bundled + user).
    static func allNames() -> [String] {
        var names = Set(bundledNames)
        if let userDir = userStylesDirectory,
           let urls = try? FileManager.default.contentsOfDirectory(
               at: userDir, includingPropertiesForKeys: nil) {
            for url in urls where url.pathExtension == "json" {
                names.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted()
    }

    // MARK: - Bundled

    private static func loadBundled(named name: String) -> VisualStyle? {
        guard bundledNames.contains(name) else { return nil }
        guard let url = BundledResource.url("Styles/\(name).json") else { return nil }
        return load(from: url)
    }

    // MARK: - User

    private static func loadUser(named name: String) -> VisualStyle? {
        guard let userDir = userStylesDirectory else { return nil }
        let url = userDir.appendingPathComponent("\(name).json")
        return load(from: url)
    }

    // MARK: - Shared

    private static func load(from url: URL) -> VisualStyle? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(VisualStyle.self, from: data)
    }

    /// Validates a loaded style and returns its report.
    static func validate(_ style: VisualStyle) -> VisualStyleValidator.Report {
        VisualStyleValidator.validate(style)
    }
}
