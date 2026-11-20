import Foundation

enum MCPExternalClient: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode
    case antigravity

    var id: String { rawValue }

    var name: String {
        localHarness.name
    }

    var localHarness: LocalAgentHarness {
        switch self {
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .antigravity: .antigravity
        }
    }

    var setupDescription: String {
        switch self {
        case .codex:
            L10n.key("Run this command once in Terminal, then restart Codex. The app and CLI share this connection.")
        case .claudeCode:
            L10n.key("Run this command once in Terminal, then start a new Claude Code session. The connection applies to all your projects.")
        case .antigravity:
            L10n.key("In Antigravity, open Customizations, choose Installed, and find MCP Servers. Use Copy Config File Path to find the configuration, merge this server entry, then restart the server. In Antigravity IDE, use the agent panel's MCP Servers menu.")
        }
    }

    var documentationURL: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex/mcp")!
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/mcp")!
        case .antigravity: URL(string: "https://antigravity.google/docs/mcp")!
        }
    }
}

@MainActor
enum MCPConnectionConfiguration {
    static var endpoint: String { "http://127.0.0.1:\(MCPService.port)/mcp" }
    static let antigravityConfigPath = "~/.gemini/config/mcp_config.json"

    static var codexCommand: String {
        "codex mcp add compositor-pro --url \(endpoint)"
    }

    static var claudeCodeCommand: String {
        "claude mcp add --transport http --scope user compositor-pro \(endpoint)"
    }

    static var antigravityConfiguration: String {
        """
        {
          "mcpServers": {
            "compositor-pro": {
              "serverUrl": "\(endpoint)"
            }
          }
        }
        """
    }

    static func setupCode(for client: MCPExternalClient) -> String {
        switch client {
        case .codex: codexCommand
        case .claudeCode: claudeCodeCommand
        case .antigravity: antigravityConfiguration
        }
    }

    static func inspectionPrompt(projectId: String?) -> String {
        guard let projectId, let id = UUID(uuidString: projectId) else {
            return """
            Use the compositor-pro MCP server. Call manage_project with action='list' and ask me which project to inspect. \
            Open that project with manage_project, then call get_timeline and summarize the current edit without changing it.
            """
        }
        return """
        Use the compositor-pro MCP server. Call manage_project with action='open' and id='\(id.uuidString)'. \
        Then call get_timeline and summarize the current edit without changing it.
        """
    }
}
