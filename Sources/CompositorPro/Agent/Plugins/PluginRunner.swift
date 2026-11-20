import Foundation

enum PluginRunError: LocalizedError {
    case blocked(String)
    case untrusted(String)
    case unsupportedScope(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let name): "Plugin '\(name)' is blocked: its bundle changed after install. Reinstall it."
        case .untrusted(let name): "Plugin '\(name)' is not trusted. Approve it in Settings › Plugins."
        case .unsupportedScope(let name): "Plugin '\(name)' requests mutating scope, which is not supported."
        }
    }
}

/// Shared trust + schema gate and sandbox dispatch used by both the MCP executor and the CLI.
/// Preparation stays on the caller's actor; only the encoded payload crosses to the worker.
enum PluginRunner {
    static func payload(for tool: PluginTool, args: [String: Any]) throws -> Data {
        let name = tool.plugin.manifest.name
        switch tool.plugin.trust {
        case .blocked: throw PluginRunError.blocked(name)
        case .untrusted: throw PluginRunError.untrusted(name)
        case .trusted: break
        }
        guard tool.plugin.manifest.permissionScope == .readOnly else {
            throw PluginRunError.unsupportedScope(name)
        }
        try PluginInputSchema.validate(args: args, schema: tool.inputSchema)
        return try JSONSerialization.data(withJSONObject: ["args": args], options: [.sortedKeys])
    }

    static func run(_ tool: PluginTool, payload: Data) async throws -> String {
        try await PluginSandbox.run(plugin: tool.plugin, payload: payload)
    }
}
