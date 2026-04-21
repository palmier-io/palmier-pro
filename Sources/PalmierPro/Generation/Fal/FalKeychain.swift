import Foundation

enum FalKeychain {
    private static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".palmier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Restrict directory to owner only
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("credentials")
    }

    static func save(_ key: String) {
        let url = fileURL
        try? Data(key.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == true ? nil : key
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
