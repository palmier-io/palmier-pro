import CryptoKit
import Foundation

struct InstalledPlugin: Sendable {
    let manifest: PluginManifest
    let directory: URL
    let trust: PluginTrustLevel
    let digest: String

    var entryPointURL: URL { directory.appendingPathComponent(manifest.entryPoint, isDirectory: false) }
}

enum PluginStoreError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Installs plugin bundles under Application Support and owns their ledger: content digest and
/// trust decision per plugin. A bundle whose bytes no longer match its digest is blocked.
final class PluginStore: Sendable {
    static let shared = PluginStore()
    static let ledgerFileName = ".installed.json"

    private struct LedgerEntry: Codable, Sendable {
        var digest: String
        var trust: PluginTrustLevel
        var installedAt: Date
    }

    let rootDirectory: URL
    private let io = ProjectPackageIO()

    init(rootDirectory: URL = PluginStore.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
    }

    static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CompositorPro/plugins", isDirectory: true)
    }

    func installedPlugins() async -> [InstalledPlugin] {
        let root = rootDirectory
        let io = io
        return await (try? io.perform { () -> [InstalledPlugin] in
            let ledger = Self.readLedger(in: root)
            return ledger.compactMap { id, entry -> InstalledPlugin? in
                let directory = root.appendingPathComponent(id, isDirectory: true)
                guard let manifest = try? PluginManifest.load(from: directory) else { return nil }
                let digest = Self.digest(of: directory, manifest: manifest)
                let trust: PluginTrustLevel = digest == entry.digest ? entry.trust : .blocked
                return InstalledPlugin(manifest: manifest, directory: directory, trust: trust, digest: digest)
            }
        }) ?? []
    }

    @discardableResult
    func install(from sourceDirectory: URL, trust: PluginTrustLevel? = nil) async throws -> InstalledPlugin {
        let root = rootDirectory
        let io = io
        return try await io.perform {
            let manifest = try PluginManifest.load(from: sourceDirectory)
            let entry = sourceDirectory.appendingPathComponent(manifest.entryPoint, isDirectory: false)
            guard FileManager.default.fileExists(atPath: entry.path) else {
                throw PluginStoreError.invalid("Plugin entry point is missing: \(manifest.entryPoint)")
            }
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
            let staging = root.appendingPathComponent(".stage-\(manifest.id)-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.copyItem(at: sourceDirectory, to: staging)
                try Self.makeExecutable(staging.appendingPathComponent(manifest.entryPoint))
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: staging, to: destination)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            let digest = Self.digest(of: destination, manifest: manifest)
            let resolvedTrust = trust ?? (manifest.signature == nil ? .untrusted : .trusted)
            var ledger = Self.readLedger(in: root)
            ledger[manifest.id] = LedgerEntry(digest: digest, trust: resolvedTrust, installedAt: Date())
            try Self.writeLedger(ledger, in: root)
            return InstalledPlugin(manifest: manifest, directory: destination, trust: resolvedTrust, digest: digest)
        }
    }

    func remove(id: String) async throws {
        let root = rootDirectory
        let io = io
        try await io.perform {
            let fm = FileManager.default
            let directory = root.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            var ledger = Self.readLedger(in: root)
            ledger.removeValue(forKey: id)
            try Self.writeLedger(ledger, in: root)
        }
    }

    func setTrust(_ trust: PluginTrustLevel, for id: String) async throws {
        let root = rootDirectory
        let io = io
        try await io.perform {
            var ledger = Self.readLedger(in: root)
            guard var entry = ledger[id] else { throw PluginStoreError.invalid("Unknown plugin: \(id)") }
            entry.trust = trust
            ledger[id] = entry
            try Self.writeLedger(ledger, in: root)
        }
    }

    /// Installs the bundled read-only sample once so the plugin loop is exercisable end to end.
    @discardableResult
    func installBuiltInSampleIfNeeded() async -> InstalledPlugin? {
        let root = rootDirectory
        let io = io
        return await (try? io.perform { () -> InstalledPlugin? in
            let fm = FileManager.default
            let id = "compositor.sample.echo"
            let directory = root.appendingPathComponent(id, isDirectory: true)
            let manifest = Self.sampleManifest
            if !fm.fileExists(atPath: directory.appendingPathComponent(PluginManifest.fileName).path) {
                try? fm.removeItem(at: directory)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.sampleManifestJSON.write(to: directory.appendingPathComponent(PluginManifest.fileName), options: .atomic)
                try Self.sampleScript.write(to: directory.appendingPathComponent(manifest.entryPoint), atomically: true, encoding: .utf8)
                try Self.makeExecutable(directory.appendingPathComponent(manifest.entryPoint))
            }
            let digest = Self.digest(of: directory, manifest: manifest)
            var ledger = Self.readLedger(in: root)
            let entry = LedgerEntry(digest: digest, trust: .trusted, installedAt: Date())
            if ledger[id]?.digest != digest { ledger[id] = entry; try Self.writeLedger(ledger, in: root) }
            return InstalledPlugin(manifest: manifest, directory: directory, trust: .trusted, digest: digest)
        }) ?? nil
    }

    // MARK: - Sample plugin

    private static let sampleManifest = PluginManifest(
        id: "compositor.sample.echo", name: "Sample Echo", version: "1.0.0",
        toolName: "sample_echo",
        toolDescription: "Read-only sample plugin. Echoes how many argument bytes it received so an agent can verify out-of-process plugin execution.",
        inputSchema: [
            "type": "object",
            "properties": ["message": ["type": "string"]],
            "additionalProperties": false,
        ],
        entryPoint: "run.sh", permissionScope: .readOnly, signature: "builtin:compositor"
    )

    private static let sampleScript = """
    #!/bin/sh
    input=$(cat)
    printf '{"result":{"plugin":"compositor.sample.echo","argumentsReceived":%s}}\\n' "${#input}"
    """

    private static var sampleManifestJSON: Data {
        let object: [String: Any] = [
            "id": sampleManifest.id,
            "name": sampleManifest.name,
            "version": sampleManifest.version,
            "signature": sampleManifest.signature ?? "",
            "permissionScope": sampleManifest.permissionScope.rawValue,
            "entryPoint": sampleManifest.entryPoint,
            "tool": [
                "name": sampleManifest.toolName,
                "description": sampleManifest.toolDescription,
                "inputSchema": sampleManifest.inputSchema,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: - Ledger and digests

    private static func ledgerURL(_ root: URL) -> URL {
        root.appendingPathComponent(ledgerFileName, isDirectory: false)
    }

    private static func readLedger(in root: URL) -> [String: LedgerEntry] {
        guard let data = try? Data(contentsOf: ledgerURL(root)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: LedgerEntry].self, from: data)) ?? [:]
    }

    private static func writeLedger(_ ledger: [String: LedgerEntry], in root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try ensureDirectory(root)
        try encoder.encode(ledger).write(to: ledgerURL(root), options: .atomic)
    }

    private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Content identity over the manifest plus the entry point, so editing either blocks the plugin.
    private static func digest(of directory: URL, manifest: PluginManifest) -> String {
        var hasher = SHA256()
        for name in [PluginManifest.fileName, manifest.entryPoint] {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            hasher.update(data: (try? Data(contentsOf: url)) ?? Data())
            hasher.update(data: Data(name.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
