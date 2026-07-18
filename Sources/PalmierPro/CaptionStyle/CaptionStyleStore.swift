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

    /// Test seam: point the machine-global / shared-library base directories at temp dirs so tests
    /// never read or write the real `~/.config/caption-style` and `~/Documents/Palmier Pro`. `@TaskLocal`
    /// is bound per test task, so it stays hermetic under the test runner's parallel execution.
    @TaskLocal static var globalDirectoryOverride: URL?
    @TaskLocal static var libraryDirectoryOverride: URL?

    /// `~/.config/caption-style/global.json` — the pattern's first ~/.config user in the app.
    static var globalURL: URL {
        (globalDirectoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/caption-style", isDirectory: true))
            .appendingPathComponent("global.json", isDirectory: false)
    }

    /// `<library>/caption-style.json` — the shared media library root.
    static var libraryURL: URL {
        (libraryDirectoryOverride ?? Project.storageDirectory)
            .appendingPathComponent(Project.captionStyleFilename, isDirectory: false)
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

    // MARK: - Single-layer write (set_caption_style / lint dismiss)

    enum WriteError: LocalizedError {
        case unwritableScope(Scope)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .unwritableScope(.builtIn): "The built-in default layer cannot be written."
            case .unwritableScope(.project): "No project is open, so the project caption-style layer cannot be written."
            case .unwritableScope(let s): "The \(s.rawValue) caption-style layer cannot be written."
            case .ioFailure(let reason): "Could not write the caption-style profile: \(reason)."
            }
        }
    }

    /// Writable file URL for a scope; nil for builtIn, or project scope with no open package.
    static func url(for scope: Scope, projectPackageURL: URL?) -> URL? {
        switch scope {
        case .builtIn: nil
        case .global: globalURL
        case .library: libraryURL
        case .project: projectURL(package: projectPackageURL)
        }
    }

    /// One scope's raw JSON object as stored on disk — empty when missing or malformed. Never throws;
    /// this is the read half of a read-modify-write that must tolerate concurrent hand edits.
    static func readLayer(at url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Merge `provided` (a validated JSON fragment in caption_style file shape) onto the single layer
    /// file at `url` and write it back. Provided keys replace that layer's values; absent keys are left
    /// untouched, including unknown keys a human hand-edited in. Nested objects merge per key; arrays
    /// and scalars replace wholesale. Read-modify-write, so concurrent hand edits to other keys survive.
    @discardableResult
    static func writeLayer(_ provided: [String: Any], at url: URL) throws -> [String: Any] {
        let merged = deepMerge(base: readLayer(at: url), over: provided)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            throw WriteError.ioFailure(error.localizedDescription)
        }
        return merged
    }

    /// Recursive object merge: same-key objects merge; arrays and scalars from `over` replace `base`.
    static func deepMerge(base: [String: Any], over: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in over {
            if let nestedOver = value as? [String: Any], let nestedBase = result[key] as? [String: Any] {
                result[key] = deepMerge(base: nestedBase, over: nestedOver)
            } else {
                result[key] = value
            }
        }
        return result
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
