import Foundation
import Testing
@testable import CompositorPro

@Suite("Plugin sandbox and registry")
struct PluginSandboxRegistryTests {
    private let fm = FileManager.default

    private func makeInstalled(
        script: String,
        toolName: String = "sandbox_probe",
        trust: PluginTrustLevel = .trusted,
        permissionScope: PluginPermissionScope = .readOnly,
        inputSchema: [String: Any]? = nil,
        directoryName: String = UUID().uuidString
    ) throws -> InstalledPlugin {
        let directory = fm.temporaryDirectory.appendingPathComponent("plugin-sandbox-\(directoryName)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            id: "test.sandbox", name: "Sandbox", version: "1.0.0",
            toolName: toolName, toolDescription: "Probe",
            inputSchema: inputSchema ?? ["type": "object", "additionalProperties": true],
            entryPoint: "run.sh", permissionScope: permissionScope, signature: "dev:test"
        )
        try "{\"id\":\"test.sandbox\"}".write(
            to: directory.appendingPathComponent(PluginManifest.fileName), atomically: true, encoding: .utf8
        )
        let entry = directory.appendingPathComponent("run.sh")
        try script.write(to: entry, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        return InstalledPlugin(manifest: manifest, directory: directory, trust: trust, digest: "digest")
    }

    @Test func sandboxReturnsThePluginResult() async throws {
        let plugin = try makeInstalled(script: "#!/bin/sh\ncat >/dev/null\nprintf '{\"result\":{\"ok\":true}}\\n'\n")
        defer { try? fm.removeItem(at: plugin.directory) }

        let result = try await PluginSandbox.run(plugin: plugin, payload: Data("{\"args\":{}}".utf8))
        #expect(result == "{\"ok\":true}")
    }

    @Test func sandboxReportsNonZeroExitWithStderr() async throws {
        let plugin = try makeInstalled(script: "#!/bin/sh\necho 'boom' >&2\nexit 4\n")
        defer { try? fm.removeItem(at: plugin.directory) }

        await #expect(throws: PluginSandboxError.self) {
            try await PluginSandbox.run(plugin: plugin, payload: Data("{}".utf8))
        }
    }

    @Test func sandboxKillsAHungPlugin() async throws {
        let plugin = try makeInstalled(script: "#!/bin/sh\nsleep 5\nprintf '{\"result\":1}\\n'\n")
        defer { try? fm.removeItem(at: plugin.directory) }

        let started = ContinuousClock.now
        await #expect(throws: PluginSandboxError.self) {
            try await PluginSandbox.run(plugin: plugin, payload: Data("{}".utf8), timeout: 0.4)
        }
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test func sandboxRejectsAReplacedEntryOutsideTheBundle() async throws {
        let plugin = try makeInstalled(script: "#!/bin/sh\nprintf '{\"result\":1}\\n'\n")
        defer { try? fm.removeItem(at: plugin.directory) }
        try fm.removeItem(at: plugin.entryPointURL)
        try fm.createSymbolicLink(at: plugin.entryPointURL, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))

        await #expect(throws: PluginSandboxError.self) {
            try await PluginSandbox.run(plugin: plugin, payload: Data("{}".utf8))
        }
    }

    @MainActor
    @Test func registryRejectsShadowingDuplicatesAndMutatingPlugins() throws {
        let plain = try makeInstalled(script: "#!/bin/sh\nprintf '{\"result\":1}\\n'", toolName: "plugin_read")
        let shadow = try makeInstalled(script: "#!/bin/sh\n", toolName: ToolName.getTimeline.rawValue)
        let duplicate = try makeInstalled(script: "#!/bin/sh\n", toolName: "plugin_read")
        let mutating = try makeInstalled(
            script: "#!/bin/sh\n", toolName: "plugin_write", permissionScope: .mutatingTools
        )
        defer {
            for plugin in [plain, shadow, duplicate, mutating] { try? fm.removeItem(at: plugin.directory) }
        }

        let registry = ToolRegistry(store: PluginStore(rootDirectory: fm.temporaryDirectory))
        registry.replace(with: [plain, shadow, duplicate, mutating])

        #expect(registry.tools.map(\.name) == ["plugin_read"])
        #expect(registry.tool(named: "get_timeline") == nil)
        #expect(registry.tool(named: "plugin_write") == nil)
    }

    @MainActor
    @Test func executorRefusesUntrustedAndBlockedPluginsWithoutLaunching() async throws {
        let untrusted = try makeInstalled(script: "#!/bin/sh\nexit 9\n", trust: .untrusted)
        let blocked = try makeInstalled(script: "#!/bin/sh\nexit 9\n", trust: .blocked)
        defer {
            try? fm.removeItem(at: untrusted.directory)
            try? fm.removeItem(at: blocked.directory)
        }
        let executor = ToolExecutor(projectProvider: { nil })

        let untrustedResult = await executor.executePluginTool(
            PluginTool(name: "sandbox_probe", description: "Probe", inputSchema: untrusted.manifest.inputSchema, plugin: untrusted),
            args: [:]
        )
        #expect(untrustedResult.isError)
        #expect(untrustedResult.text.contains("not trusted"))

        let blockedResult = await executor.executePluginTool(
            PluginTool(name: "sandbox_probe", description: "Probe", inputSchema: blocked.manifest.inputSchema, plugin: blocked),
            args: [:]
        )
        #expect(blockedResult.isError)
        #expect(blockedResult.text.contains("blocked"))
    }

    @MainActor
    @Test func executorValidatesArgumentsBeforeLaunching() async throws {
        let plugin = try makeInstalled(
            script: "#!/bin/sh\nprintf '{\"result\":{\"ran\":true}}\\n'\n",
            inputSchema: [
                "type": "object",
                "properties": ["message": ["type": "string"]],
                "required": ["message"],
                "additionalProperties": false,
            ]
        )
        defer { try? fm.removeItem(at: plugin.directory) }
        let executor = ToolExecutor(projectProvider: { nil })
        let tool = PluginTool(name: "sandbox_probe", description: "Probe", inputSchema: plugin.manifest.inputSchema, plugin: plugin)

        let refused = await executor.executePluginTool(tool, args: ["wrong": true])
        #expect(refused.isError)
        let accepted = await executor.executePluginTool(tool, args: ["message": "hi"])
        #expect(accepted.text == "{\"ran\":true}")
    }
}
