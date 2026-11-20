import Foundation
import Testing
@testable import CompositorPro

@Suite("External agent connection setup")
@MainActor
struct MCPConnectionConfigurationTests {
    @Test(arguments: MCPExternalClient.allCases)
    func setupsUseThePublishedHTTPServer(client: MCPExternalClient) throws {
        let endpoint = try #require(URL(string: MCPConnectionConfiguration.endpoint))
        #expect(endpoint.scheme == "http")
        #expect(endpoint.host == "127.0.0.1")
        #expect(endpoint.port == Int(MCPService.port))
        #expect(endpoint.path == "/mcp")

        let setup = MCPConnectionConfiguration.setupCode(for: client)
        switch client {
        case .codex:
            #expect(setup.components(separatedBy: " ") == [
                "codex", "mcp", "add", "compositor-pro", "--url", endpoint.absoluteString,
            ])
        case .claudeCode:
            #expect(setup.components(separatedBy: " ") == [
                "claude", "mcp", "add", "--transport", "http", "--scope", "user",
                "compositor-pro", endpoint.absoluteString,
            ])
        case .antigravity:
            let json = try #require(JSONSerialization.jsonObject(with: Data(setup.utf8)) as? [String: Any])
            let servers = try #require(json["mcpServers"] as? [String: [String: String]])
            #expect(servers == ["compositor-pro": ["serverUrl": endpoint.absoluteString]])
            #expect(MCPConnectionConfiguration.antigravityConfigPath == "~/.gemini/config/mcp_config.json")
        }
    }

    @Test func inspectionPromptBindsTheSelectedProject() {
        let id = UUID()
        let prompt = MCPConnectionConfiguration.inspectionPrompt(projectId: id.uuidString)
        #expect(prompt.contains("manage_project with action='open' and id='\(id.uuidString)'"))
        #expect(prompt.contains("get_timeline"))
        #expect(prompt.contains("without changing it"))
    }

    @Test(arguments: [nil, "", "not-a-project-id"] as [String?])
    func unknownProjectRequiresSelectionBeforeInspection(projectId: String?) {
        let prompt = MCPConnectionConfiguration.inspectionPrompt(projectId: projectId)
        #expect(prompt.contains("action='list'"))
        #expect(prompt.contains("ask me which project"))
        #expect(!prompt.contains("id='"))
    }
}
