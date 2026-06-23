import Foundation

/// Builds the argv / env / cwd for the interactive Claude Code session embedded
/// in the Agent Panel. It connects to Palmier's local MCP server and runs with
/// permissions bypassed, so it can drive the editor without per-tool prompts.
enum ClaudeCodeTerminalCommand {

    @MainActor
    static func arguments(model: String) -> [String] {
        [
            "--mcp-config", mcpConfigJSON,
            "--strict-mcp-config",
            "--append-system-prompt", AgentInstructions.serverInstructions,
            "--dangerously-skip-permissions",
            "--model", model,
        ]
    }

    @MainActor
    static var mcpConfigJSON: String {
        let endpoint = "http://127.0.0.1:\(MCPService.port)/mcp"
        let config: [String: Any] = [
            "mcpServers": ["palmier-pro": ["type": "http", "url": endpoint]],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{\"mcpServers\":{\"palmier-pro\":{\"type\":\"http\",\"url\":\"\(endpoint)\"}}}"
    }

    /// The terminal opens in the project itself — Palmier projects are `.palmier`
    /// file packages (directories), so `claude`'s cwd is the exact bundle open in
    /// the editor. Checks the filesystem (not the URL's trailing slash) so a
    /// package URL resolves to the package, not its parent.
    static func workingDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? projectURL : projectURL.deletingLastPathComponent()
            }
        }
        return FileManager.default.temporaryDirectory
    }

    /// PTY environment: inherit the user's, but augment PATH so node/claude resolve
    /// even when the app was launched from Finder.
    static func environment(claudePath: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeCodeLocator.augmentedPath(forBinary: claudePath, base: env["PATH"])
        env["TERM"] = "xterm-256color"
        return env.map { "\($0.key)=\($0.value)" }
    }
}
