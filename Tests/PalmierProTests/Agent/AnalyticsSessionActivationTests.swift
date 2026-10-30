import Testing
@testable import PalmierPro

@Suite("Analytics session activation")
struct AnalyticsSessionActivationTests {
    @Test func capturesOnlyFirstActivation() {
        var activation = Analytics.SessionActivation()

        let firstActivation = activation.activate()
        let secondActivation = activation.activate()

        #expect(firstActivation)
        #expect(!secondActivation)
        #expect(activation.isActivated)
    }

    @Test func restoredActiveSessionDoesNotCaptureAgain() {
        var activation = Analytics.SessionActivation(isActivated: true)

        let repeatedActivation = activation.activate()

        #expect(!repeatedActivation)
    }

    @Test func mcpClientInfoPreservesReportedJSONFields() {
        let info = MCPClientInfo(
            name: "claude-code",
            title: "Claude Code",
            version: "2.1.212",
            description: "Anthropic's agentic coding tool",
            websiteUrl: "https://claude.com/claude-code"
        )

        #expect(info.payload["name"] as? String == "claude-code")
        #expect(info.payload["title"] as? String == "Claude Code")
        #expect(info.payload["version"] as? String == "2.1.212")
        #expect(info.payload["description"] as? String == "Anthropic's agentic coding tool")
        #expect(info.payload["websiteUrl"] as? String == "https://claude.com/claude-code")
    }

    @Test func mcpClientInfoOmitsUnreportedOptionalFields() {
        let info = MCPClientInfo(name: "codex-mcp-client", version: "0.144.5")

        #expect(Set(info.payload.keys) == ["name", "version"])
    }

    @Test @MainActor func mcpSessionActivationIncludesClientInfo() throws {
        let executor = ToolExecutor(projectProvider: { nil })
        executor.setMCPClientInfo(MCPClientInfo(name: "Cursor", version: "1.0.0"))

        let properties = executor.mcpSessionActivationProperties(toolName: "get_timeline")
        let clientInfo = try #require(properties["client_info"] as? Analytics.Payload)

        #expect(properties["source"] as? String == "mcp")
        #expect((properties["session_id"] as? String)?.isEmpty == false)
        #expect(properties["tool_name"] as? String == "get_timeline")
        #expect(clientInfo["name"] as? String == "Cursor")
        #expect(clientInfo["version"] as? String == "1.0.0")
    }

    @Test @MainActor func toolErrorMessageOmitsAbsolutePathsAndURLs() {
        let result = ToolResult.error(
            """
            Import failed at /Users/editor/Library/Application Support/secret.mov
            Download failed from https://example.com/private
            Retry the operation.
            """
        )

        let message = ToolExecutor.sanitizedToolErrorMessage(result)

        #expect(message?.contains("Import failed") == true)
        #expect(message?.contains("Application Support") == false)
        #expect(message?.contains("secret.mov") == false)
        #expect(message?.contains("example.com") == false)
        #expect(message?.contains("Retry the operation.") == true)
    }
}
