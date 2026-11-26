import Foundation

/// A dispatchable plugin tool: plugin identity plus the schema agents see.
struct PluginTool: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let plugin: InstalledPlugin
}

/// Merges installed plugin tools with the built-in tool catalog. Built-in names always win, so a
/// plugin can never shadow a project-mutating tool.
@MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()

    private(set) var tools: [PluginTool] = []
    private var byName: [String: PluginTool] = [:]
    private var isLoaded = false
    private let store: PluginStore

    init(store: PluginStore = .shared) {
        self.store = store
    }

    func tool(named name: String) -> PluginTool? { byName[name] }

    /// Loads installed bundles from the plugin store. The sample is installed at app launch.
    func ensureLoaded() async {
        guard !isLoaded else { return }
        await reload()
    }

    func reload() async {
        isLoaded = true
        replace(with: await store.installedPlugins())
    }

    /// Validates names and rebuilds the index. Rejected tools are logged, never registered.
    func replace(with plugins: [InstalledPlugin]) {
        var next: [String: PluginTool] = [:]
        for installed in plugins.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            let manifest = installed.manifest
            guard manifest.permissionScope == .readOnly else {
                Log.mcp.warning("plugin tool skipped (mutating scope unsupported) id=\(manifest.id)")
                continue
            }
            guard ToolName(rawValue: manifest.toolName) == nil else {
                Log.mcp.warning("plugin tool skipped (name shadows built-in) id=\(manifest.id) name=\(manifest.toolName)")
                continue
            }
            guard next[manifest.toolName] == nil else {
                Log.mcp.warning("plugin tool skipped (duplicate tool name) id=\(manifest.id) name=\(manifest.toolName)")
                continue
            }
            next[manifest.toolName] = PluginTool(
                name: manifest.toolName,
                description: manifest.toolDescription,
                inputSchema: manifest.inputSchema,
                plugin: installed
            )
        }
        byName = next
        tools = next.values.sorted { $0.name < $1.name }
    }
}
