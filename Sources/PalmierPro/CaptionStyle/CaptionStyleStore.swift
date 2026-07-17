// Layered load-and-merge for the caption-style profile: global → library → project, later wins.
// Malformed or missing files fall back to defaults with a warning; a bad file never crashes or blocks.

import Foundation

enum CaptionStyleStore {
    enum Scope: String, Sendable { case builtIn, global, library, project }
    enum Status: String, Sendable { case loaded, missing, malformed }

    struct Origin: Sendable {
        let scope: Scope
        let path: String
        let status: Status
    }

    struct Resolved: Sendable {
        let profile: CaptionStyleProfile
        let origins: [Origin]
        let warnings: [String]
    }

    /// `~/.config/caption-style/global.json` — the pattern's first ~/.config user in the app.
    static var globalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/caption-style/global.json", isDirectory: false)
    }

    /// `<library>/caption-style.json` — the shared media library root.
    static var libraryURL: URL {
        Project.storageDirectory.appendingPathComponent(Project.captionStyleFilename, isDirectory: false)
    }

    /// `<project>.palmier/caption-style.json` — sidecar inside the project package.
    static func projectURL(package: URL?) -> URL? {
        package?.appendingPathComponent(Project.captionStyleFilename, isDirectory: false)
    }

    /// Resolve the effective profile for a project. Reads at most three small files.
    static func resolve(projectPackageURL: URL?) -> Resolved {
        var accumulated = CaptionStyleProfilePartial(from: .builtInDefault)
        var origins: [Origin] = [Origin(scope: .builtIn, path: "(built-in default)", status: .loaded)]
        var warnings: [String] = []

        let layers: [(Scope, URL?)] = [
            (.global, globalURL),
            (.library, libraryURL),
            (.project, projectURL(package: projectPackageURL)),
        ]

        for (scope, url) in layers {
            guard let url else { continue }
            switch load(url) {
            case .loaded(let partial):
                accumulated = accumulated.overlaid(by: partial)
                origins.append(Origin(scope: scope, path: url.path, status: .loaded))
            case .missing:
                origins.append(Origin(scope: scope, path: url.path, status: .missing))
            case .malformed(let reason):
                warnings.append("\(scope.rawValue) profile ignored (\(reason)): \(url.path)")
                origins.append(Origin(scope: scope, path: url.path, status: .malformed))
            }
        }

        return Resolved(profile: accumulated.resolved(), origins: origins, warnings: warnings)
    }

    private enum LoadResult {
        case loaded(CaptionStyleProfilePartial)
        case missing
        case malformed(String)
    }

    private static func load(_ url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .malformed("unreadable") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return .malformed("invalid JSON") }
        guard let obj = json as? [String: Any] else { return .malformed("not a JSON object") }
        return .loaded(CaptionStyleProfilePartial(jsonObject: obj))
    }
}
