import Foundation

/// A credential file for builds macOS will not give a keychain identity.
///
/// An ad-hoc signed binary has no team identifier, so it owns no keychain access group:
/// every read prompts for the login password, and a grant lasts only for that exact
/// binary — so the next rebuild prompts again. Storing credentials in a `0600` file
/// removes the prompt for development. The keychain stays the store for signed builds,
/// where it is the only thing that protects a credential at rest.
struct DevSecretStore: Sendable {
    static let defaultFileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CompositorPro/secrets.json", isDirectory: false)

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL = DevSecretStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func save(_ value: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        var secrets = readAll()
        secrets[account] = value
        writeAll(secrets)
    }

    func load(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = readAll()[account]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        var secrets = readAll()
        guard secrets.removeValue(forKey: account) != nil else { return }
        writeAll(secrets)
    }

    // MARK: - Storage

    private func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func writeAll(_ secrets: [String: String]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            // Sorted keys keep the file stable, so a rewrite differs only where a secret did.
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(secrets).write(to: fileURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.app.error(
                "Credential file write failed for \(self.fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }
}