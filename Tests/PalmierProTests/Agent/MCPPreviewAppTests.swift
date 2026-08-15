import Foundation
import MCP
import Testing

@testable import PalmierPro

struct MCPPreviewAppTests {
    @Test func generateImageDeclaresPreviewResource() throws {
        guard case .object(let ui)? = MCPPreviewApp.toolMeta["ui"] else {
            Issue.record("generate_image must declare _meta.ui")
            return
        }
        #expect(ui["resourceUri"] == .string(MCPPreviewApp.resourceURI))
        #expect(MCPPreviewApp.resourceURI.hasPrefix("ui://"))
        #expect(MCPPreviewApp.mimeType == "text/html;profile=mcp-app")
    }

    @Test func htmlCompletesHostHandshakeAndShowsImage() {
        let html = MCPPreviewApp.html
        #expect(!html.isEmpty)
        #expect(html.contains("ui/initialize"))
        #expect(html.contains("ui/notifications/initialized"))
        #expect(html.contains("ui/notifications/tool-input"))
        #expect(html.contains("ui/notifications/tool-result"))
        #expect(html.contains("Generating"))
        #expect(html.contains("data:${block.mimeType"))
    }
}
