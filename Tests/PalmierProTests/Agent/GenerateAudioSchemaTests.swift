import MCP
import Testing
@testable import PalmierPro

struct GenerateAudioSchemaTests {
    @Test func mcpSchemaExposesSeedAudioOptions() throws {
        let tool = try #require(ToolDefinitions.mcpServer.first { $0.name == .generateAudio })
        guard case .object(let schema) = tool.mcpSchemaValue,
              case .object(let properties) = schema["properties"] else {
            Issue.record("generate_audio must expose an MCP object schema")
            return
        }

        #expect(properties["referenceImageMediaRefs"] != nil)
        #expect(properties["referenceAudioMediaRefs"] != nil)
        #expect(properties["multilingual"] != nil)
    }
}
