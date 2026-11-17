import Foundation

/// Headless plugin management: `plugin list`, `plugin run`, `plugin trust`, `plugin install`.
enum PluginCLI {
    static func run(_ arguments: [String], store: PluginStore = .shared) async throws -> String {
        guard let action = arguments.first?.lowercased() else {
            return helpText()
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "list":
            let plugins = await store.installedPlugins()
            let rows: [[String: Any]] = plugins.map { plugin in
                [
                    "id": plugin.manifest.id,
                    "name": plugin.manifest.name,
                    "version": plugin.manifest.version,
                    "tool": plugin.manifest.toolName,
                    "trust": plugin.trust.rawValue,
                    "digest": plugin.digest,
                ]
            }
            return try jsonString(rows)

        case "run":
            guard let name = rest.first else { throw CLIError.missingArgument("plugin run needs a tool name") }
            let args = try parseArgs(rest.dropFirst())
            let plugins = await store.installedPlugins()
            guard let installed = plugins.first(where: { $0.manifest.toolName == name }) else {
                throw CLIError.missingArgument("no installed plugin exposes tool '\(name)'")
            }
            let tool = PluginTool(
                name: installed.manifest.toolName,
                description: installed.manifest.toolDescription,
                inputSchema: installed.manifest.inputSchema,
                plugin: installed
            )
            return try await PluginRunner.run(tool, payload: try PluginRunner.payload(for: tool, args: args))

        case "trust":
            guard rest.count == 2, let level = PluginTrustLevel(rawValue: rest[1]) else {
                throw CLIError.missingArgument("usage: plugin trust <id> trusted|untrusted|blocked")
            }
            try await store.setTrust(level, for: rest[0])
            return "Plugin \(rest[0]) is now \(level.rawValue)."

        case "install":
            guard let path = rest.first else { throw CLIError.missingArgument("plugin install needs a folder path") }
            let installed = try await store.install(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            return "Installed \(installed.manifest.name) (\(installed.manifest.toolName), \(installed.trust.rawValue))."

        case "help", "--help", "-h":
            return helpText()

        default:
            throw CLIError.missingArgument("unknown plugin action '\(action)'")
        }
    }

    /// Parses `--args '{"k": 1}'`; rejects anything that is not one JSON object.
    private static func parseArgs(_ arguments: ArraySlice<String>) throws -> [String: Any] {
        let args = Array(arguments)
        guard let flagIndex = args.firstIndex(of: "--args") else { return [:] }
        guard flagIndex + 1 < args.count else { throw CLIError.missingArgument("--args needs a JSON object") }
        guard let data = args[flagIndex + 1].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.missingArgument("--args must be a JSON object")
        }
        return object
    }

    private static func jsonString(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw CLIError.missingArgument("could not encode plugin output")
        }
        return text
    }

    static func helpText() -> String {
        """
        plugin <action> [options]
          Manage agent plugins (read-only tools that run out of process).

          Actions:
            list                                  Print installed plugins as JSON
            run <toolName> [--args <json>]        Run one plugin tool and print its result JSON
            trust <id> trusted|untrusted|blocked  Change a plugin's trust decision
            install <folder>                      Install a plugin folder containing plugin.json
        """
    }
}
