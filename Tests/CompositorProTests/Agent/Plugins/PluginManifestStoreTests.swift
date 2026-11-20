import Foundation
import Testing
@testable import CompositorPro

@Suite("Plugin manifests and stores")
struct PluginManifestStoreTests {
    private let fm = FileManager.default

    private func makeRoot() -> URL {
        fm.temporaryDirectory.appendingPathComponent("plugin-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func writePlugin(
        in root: URL,
        id: String = "test.echo",
        toolName: String = "test_echo",
        entryScript: String = "#!/bin/sh\ncat >/dev/null\nprintf '{\"result\":{\"ok\":true}}\\n'\n",
        signature: String? = "dev:test",
        permissionScope: String = "read-only"
    ) throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "id": id, "name": "Test Echo", "version": "1.0.0",
            "entryPoint": "run.sh", "permissionScope": permissionScope,
            "tool": [
                "name": toolName,
                "description": "Echo test plugin",
                "inputSchema": [
                    "type": "object",
                    "properties": ["message": ["type": "string"]],
                    "additionalProperties": false,
                ],
            ],
        ]
        if let signature { manifest["signature"] = signature }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(PluginManifest.fileName))
        let entry = directory.appendingPathComponent("run.sh")
        try entryScript.write(to: entry, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        return directory
    }

    @Test func manifestRejectsUnsafeEntryPointsAndSchemas() throws {
        let root = makeRoot()
        defer { try? fm.removeItem(at: root) }
        _ = try makePluginWrite(root: root)

        let manifest = try PluginManifest.load(from: root.appendingPathComponent("test.echo"))
        #expect(manifest.toolName == "test_echo")
        #expect(manifest.permissionScope == .readOnly)

        let escape: [String: Any] = [
            "id": "test.escape", "name": "Escape", "version": "1", "entryPoint": "../run.sh",
            "tool": ["name": "escape_tool", "description": "x", "inputSchema": ["type": "object"]],
        ]
        #expect(throws: PluginManifestError.self) { try PluginManifest.parse(escape) }

        let badSchema: [String: Any] = [
            "id": "test.schema", "name": "Schema", "version": "1", "entryPoint": "run.sh",
            "tool": ["name": "schema_tool", "description": "x", "inputSchema": ["type": "string"]],
        ]
        #expect(throws: PluginManifestError.self) { try PluginManifest.parse(badSchema) }

        let badID: [String: Any] = [
            "id": "Bad ID", "name": "Bad", "version": "1", "entryPoint": "run.sh",
            "tool": ["name": "bad_tool", "description": "x", "inputSchema": ["type": "object"]],
        ]
        #expect(throws: PluginManifestError.self) { try PluginManifest.parse(badID) }
    }

    @Test func argumentsAreValidatedAgainstTheDeclaredSchema() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["message": ["type": "string"], "count": ["type": "integer"]],
            "required": ["message"],
            "additionalProperties": false,
        ]
        #expect(throws: PluginManifestError.self) { try PluginInputSchema.validate(args: [:], schema: schema) }
        #expect(throws: PluginManifestError.self) {
            try PluginInputSchema.validate(args: ["message": "hi", "extra": 1], schema: schema)
        }
        #expect(throws: PluginManifestError.self) {
            try PluginInputSchema.validate(args: ["message": 3], schema: schema)
        }
        try PluginInputSchema.validate(args: ["message": "hi", "count": 2], schema: schema)
    }

    @Test func installRecordsLedgerTrustAndTamperBlocksIt() async throws {
        let root = makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let source = try makePluginWrite(root: sourceRoot)
        let store = PluginStore(rootDirectory: root.appendingPathComponent("installed"))

        let installed = try await store.install(from: source)
        #expect(installed.trust == .trusted)
        #expect(fm.fileExists(atPath: store.rootDirectory.appendingPathComponent(PluginStore.ledgerFileName).path))

        let loaded = await store.installedPlugins()
        #expect(loaded.count == 1)
        #expect(loaded.first?.digest == installed.digest)
        #expect(loaded.first?.trust == .trusted)

        // Editing the entry point after install invalidates the recorded digest.
        let entry = installed.directory.appendingPathComponent("run.sh")
        try "#!/bin/sh\nexit 3\n".write(to: entry, atomically: true, encoding: .utf8)
        let tampered = await store.installedPlugins()
        #expect(tampered.first?.trust == .blocked)

        try await store.setTrust(.untrusted, for: installed.manifest.id)
        let approved = await store.installedPlugins()
        #expect(approved.first?.trust == .blocked)

        try await store.remove(id: installed.manifest.id)
        #expect(await store.installedPlugins().isEmpty)
    }

    @Test func unsignedPluginsInstallUntrusted() async throws {
        let root = makeRoot()
        defer { try? fm.removeItem(at: root) }
        let source = try makePluginWrite(root: root.appendingPathComponent("source"), signature: nil)
        let store = PluginStore(rootDirectory: root.appendingPathComponent("installed"))
        let installed = try await store.install(from: source)
        #expect(installed.trust == .untrusted)
    }

    @Test func samplePluginInstallsOnceAndStaysTrusted() async throws {
        let root = makeRoot()
        defer { try? fm.removeItem(at: root) }
        let store = PluginStore(rootDirectory: root)

        let first = try #require(await store.installBuiltInSampleIfNeeded())
        #expect(first.manifest.toolName == "sample_echo")
        #expect(first.trust == .trusted)
        let second = try #require(await store.installBuiltInSampleIfNeeded())
        #expect(second.digest == first.digest)
        #expect(await store.installedPlugins().count == 1)
    }

    private func makePluginWrite(root: URL, signature: String? = "dev:test") throws -> URL {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return try writePlugin(in: root, signature: signature)
    }
}
