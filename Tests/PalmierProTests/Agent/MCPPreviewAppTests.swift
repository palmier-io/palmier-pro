import Foundation
import MCP
import Testing

@testable import PalmierPro

struct MCPPreviewAppTests {
    @Test func generateToolsDeclarePreviewResource() {
        for name in [ToolName.generateImage, .generateVideo, .generateAudio, .showTimeline] {
            guard case .object(let ui)? = MCPPreviewApp.meta(for: name)?["ui"] else {
                Issue.record("\(name.rawValue) must declare _meta.ui")
                continue
            }
            #expect(ui["resourceUri"] == .string(MCPPreviewApp.resourceURI))
        }
        #expect(MCPPreviewApp.resourceURI.hasPrefix("ui://"))
        #expect(MCPPreviewApp.mimeType == "text/html;profile=mcp-app")
    }

    @Test func previewPollerIsAppVisibleOnly() {
        guard case .object(let ui)? = MCPPreviewApp.meta(for: .getGenerationPreview)?["ui"] else {
            Issue.record("get_generation_preview must declare app visibility")
            return
        }
        #expect(ui["visibility"] == .array([.string("app")]))
        #expect(ToolDefinitions.mcpServer.contains(where: { $0.name == .getGenerationPreview }))
        #expect(!ToolDefinitions.inAppAgent.contains(where: { $0.name == .getGenerationPreview }))
        #expect(!ToolDefinitions.all.contains(where: { $0.name == .getGenerationPreview }))
        guard case .object(let revealUI)? = MCPPreviewApp.meta(for: .revealGenerationMedia)?["ui"] else {
            Issue.record("reveal_generation_media must declare app visibility")
            return
        }
        #expect(revealUI["visibility"] == .array([.string("app")]))
        #expect(ToolDefinitions.mcpServer.contains(where: { $0.name == .revealGenerationMedia }))
        #expect(!ToolDefinitions.inAppAgent.contains(where: { $0.name == .revealGenerationMedia }))
        #expect(!ToolDefinitions.all.contains(where: { $0.name == .revealGenerationMedia }))
        guard case .object(let timelineUI)? = MCPPreviewApp.meta(for: .revealTimeline)?["ui"] else {
            Issue.record("reveal_timeline must declare app visibility")
            return
        }
        #expect(timelineUI["visibility"] == .array([.string("app")]))
        #expect(ToolDefinitions.mcpServer.contains(where: { $0.name == .revealTimeline }))
        #expect(!ToolDefinitions.inAppAgent.contains(where: { $0.name == .revealTimeline }))
        #expect(!ToolDefinitions.all.contains(where: { $0.name == .revealTimeline }))
        #expect(ToolDefinitions.all.contains(where: { $0.name == .showTimeline }))
    }

    @Test func htmlWaitsForPalmierCompletion() {
        let html = MCPPreviewApp.html
        #expect(html.contains("ui/initialize"))
        #expect(html.contains("get_generation_preview"))
        #expect(html.contains("notifications/resources/updated"))
        #expect(html.contains("modelIconKey"))
        #expect(html.contains("aspectRatio"))
        #expect(html.contains("duration"))
        #expect(html.contains("resolution"))
        #expect(html.contains("kind === \"audio\""))
        #expect(html.contains("kind === \"video\""))
        #expect(html.contains("mediaUrl"))
        #expect(html.contains("credits"))
        #expect(html.contains("groupRole"))
        #expect(html.contains("groupMembers"))
        #expect(html.contains("async function showResult"))
        #expect(html.contains("async function applyReady"))
        #expect(html.contains("mediaResourceUri"))
        #expect(html.contains("prompt-drop"))
        #expect(html.contains("<details"))
        #expect(html.contains("includeMedia"))
        #expect(html.contains("reveal_generation_media"))
        #expect(html.contains("video.controls = true"))
        #expect(html.contains("Show in Finder"))
        #expect(html.contains("View in Palmier"))
        #expect(html.contains("reveal_timeline"))
        #expect(html.contains("kind === \"timeline\""))
        #expect(html.contains("isBurstKind"))
        #expect(html.contains("stage.portrait"))
        #expect(html.contains("groupRole === \"host\" && mediaRef"))
        #expect(html.contains("gallery"))
        #expect(html.contains("collapsed"))
    }

    @Test func previewMediaRefRejectsUnsafePaths() {
        #expect(MCPPreviewApp.isPreviewMediaRef("A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
        #expect(!MCPPreviewApp.isPreviewMediaRef("../secret"))
        #expect(!MCPPreviewApp.isPreviewMediaRef("short"))
        #expect(!MCPPreviewApp.isPreviewMediaRef("has space-xxxxxxxx"))
        #expect(!MCPPreviewApp.isPreviewMediaRef(""))
    }

    @Test func previewResourceAllowsLocalhostMedia() {
        guard case .object(let ui) = MCPPreviewApp.resourceMeta["ui"],
              case .object(let csp) = ui["csp"],
              case .array(let connect) = csp["connectDomains"],
              case .array(let resources) = csp["resourceDomains"]
        else {
            Issue.record("preview HTML must declare localhost CSP")
            return
        }
        let origin = Value.string(MCPPreviewApp.previewOrigin)
        #expect(connect == [origin])
        #expect(resources.contains(origin))
        #expect(resources.contains(.string("blob:")))
        #expect(resources.contains(.string("data:")))
        #expect(MCPPreviewApp.httpMediaURL(mediaRef: "asset-id").hasPrefix("http://127.0.0.1:19789/preview/"))
        #expect(MCPPreviewApp.httpMediaMIMEType(url: URL(fileURLWithPath: "/tmp/clip.mp4"), type: .video) == "video/mp4")
        #expect(MCPPreviewApp.httpMediaMIMEType(url: URL(fileURLWithPath: "/tmp/clip.mov"), type: .video) == "video/quicktime")
        #expect(MCPPreviewApp.httpMediaMIMEType(url: URL(fileURLWithPath: "/tmp/clip.m4a"), type: .audio) == "audio/mp4")
    }
}
