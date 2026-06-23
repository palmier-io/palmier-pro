import Foundation

/// Resolves the `claude` (Claude Code) executable. A Finder-launched GUI app
/// inherits a minimal PATH and won't see nvm/Homebrew installs, so we ask a
/// login+interactive shell and then fall back to scanning known locations.
enum ClaudeCodeLocator {

    /// PATH fragments to prepend to a spawned `claude`'s environment so its own
    /// child lookups (node, etc.) resolve. Built from the resolved binary's dir
    /// plus the usual install roots.
    static func augmentedPath(forBinary binary: String?, base: String?) -> String {
        var parts: [String] = []
        if let binary { parts.append((binary as NSString).deletingLastPathComponent) }
        parts.append(contentsOf: commonBinDirs())
        if let base, !base.isEmpty { parts.append(contentsOf: base.split(separator: ":").map(String.init)) }
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Blocking lookup. Call off the main actor (e.g. `Task.detached`).
    static func find() -> String? {
        if let viaShell = viaLoginShell() { return viaShell }
        return viaScan()
    }

    private static func viaLoginShell() -> String? {
        for shell in ["/bin/zsh", "/bin/bash"] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            // -l login (sources profile), -i interactive (sources rc where nvm lives)
            process.arguments = [shell.hasSuffix("zsh") ? "-lic" : "-lic", "command -v claude"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do {
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard let text = String(data: data, encoding: .utf8) else { continue }
                if let path = text
                    .split(separator: "\n")
                    .map({ $0.trimmingCharacters(in: .whitespaces) })
                    .last(where: { $0.hasPrefix("/") && $0.hasSuffix("claude") }),
                    FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func viaScan() -> String? {
        for dir in commonBinDirs() {
            let candidate = (dir as NSString).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func commonBinDirs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = [
            "\(home)/.claude/local",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        // nvm: ~/.nvm/versions/node/<v>/bin
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in versions.sorted(by: >) { dirs.append("\(nvmRoot)/\(v)/bin") }
        }
        return dirs
    }
}
