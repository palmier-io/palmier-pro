import Foundation
import Testing
@testable import PalmierPro

@Suite("Agent tool definitions")
struct ToolDefinitionAvailabilityTests {
    @Test func alignCaptionsIsHiddenWhenVolcengineUnavailable() throws {
        let unavailable = ToolDefinitions.Availability(captionAlignmentAvailable: false)
        let available = ToolDefinitions.Availability(captionAlignmentAvailable: true)

        #expect(ToolDefinitions.mcpTools(availability: unavailable).contains { $0.name == .alignCaptions } == false)
        #expect(ToolDefinitions.inAppAgent(availability: unavailable).contains { $0.name == .alignCaptions } == false)
        #expect(ToolDefinitions.mcpTools(availability: available).contains { $0.name == .alignCaptions })
        #expect(ToolDefinitions.inAppAgent(availability: available).contains { $0.name == .alignCaptions })
    }

    @Test func addCaptionsExposesTranscriptionProviderSchema() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .addCaptions })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let provider = try #require(properties["transcriptionProvider"] as? [String: Any])
        let values = try #require(provider["enum"] as? [String])

        #expect(values.contains("local"))
        #expect(values.contains("volcengine"))
    }
}
