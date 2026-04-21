import Foundation

enum FalKeychain {
    private static let filename = "fal-credentials"
    /// Legacy path (`~/.palmier/credentials`) from before multi-service keys.
    /// One-shot migrated on first `load` / `save`.
    private static let legacyFilename = "credentials"

    static func save(_ key: String) {
        FileCredentialStore.save(key, filename: filename)
        FileCredentialStore.delete(filename: legacyFilename)
    }

    static func load() -> String? {
        if let key = FileCredentialStore.load(filename: filename) { return key }
        guard let legacy = FileCredentialStore.load(filename: legacyFilename) else { return nil }
        save(legacy)
        return legacy
    }

    static func delete() {
        FileCredentialStore.delete(filename: filename)
        FileCredentialStore.delete(filename: legacyFilename)
    }
}
