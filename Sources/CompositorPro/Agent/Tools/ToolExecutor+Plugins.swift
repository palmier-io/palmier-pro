import Foundation

extension ToolExecutor {
    /// Runs one plugin tool out of process after schema and trust checks. Refusals are surfaced as
    /// tool errors so agents see the remedy instead of an empty result.
    func executePluginTool(_ tool: PluginTool, args: [String: Any]) async -> ToolResult {
        do {
            let payload = try PluginRunner.payload(for: tool, args: args)
            return .ok(try await PluginRunner.run(tool, payload: payload))
        } catch let error as LocalizedError {
            return .error(error.errorDescription ?? "Plugin '\(tool.name)' failed.")
        } catch {
            return .error("Plugin '\(tool.name)' failed: \(error.localizedDescription)")
        }
    }
}
