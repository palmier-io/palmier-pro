import Foundation

/// `~/.palmier/` file-backed credential store (0o700 dir, 0o600 files).
enum FileCredentialStore {
    private static let dirURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".palmier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    static func save(_ key: String, filename: String) {
        let url = dirURL.appendingPathComponent(filename)
        try? Data(key.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(filename: String) -> String? {
        let url = dirURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    static func delete(filename: String) {
        let url = dirURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
