import Foundation
import Testing
@testable import CompositorPro

struct CustomEndpointVisionTests {
    @Test(arguments: [false, true])
    func toolImagesPreserveOrderedContentAfterAllResults(isError: Bool) throws {
        let output: [ToolResult.Block] = [
            .text(#"{"mediaRef":"asset-1","frame":12}"#),
            .image(base64: "Zmlyc3Q=", mediaType: "image/png"),
            .text(#"{"mediaRef":"asset-1","frame":24}"#),
            .image(base64: "c2Vjb25k", mediaType: "image/jpeg"),
        ]
        let wire = try messages([
            calls(["inspect", "inventory"]),
            AgentRequestMessage(role: .user, content: [
                .content(.toolResult(toolUseId: "inspect", content: output, isError: isError)),
                .content(.toolResult(toolUseId: "inventory", content: [.text("Inventory")], isError: false)),
            ]),
        ])

        #expect(wire.compactMap { $0["role"] as? String } == ["assistant", "tool", "tool", "user"])
        let attachment = try #require(wire.last?["content"] as? [[String: Any]])
        #expect(attachment.compactMap { $0["type"] as? String } == ["text", "text", "image_url", "text", "image_url"])
        let label = try #require(attachment.first?["text"] as? String)
        #expect(label.contains("inspect"))
        #expect(label.contains("Tool error") == isError)
        #expect(attachment.compactMap { $0["text"] as? String }.dropFirst() == [
            #"{"mediaRef":"asset-1","frame":12}"#,
            #"{"mediaRef":"asset-1","frame":24}"#,
        ])
        #expect(imageURLs(attachment) == ["data:image/png;base64,Zmlyc3Q=", "data:image/jpeg;base64,c2Vjb25k"])
        let toolReplies = wire.filter { $0["role"] as? String == "tool" }
        #expect(toolReplies.compactMap { $0["tool_call_id"] as? String } == ["inspect", "inventory"])
        #expect(toolReplies.last?["content"] as? String == "Inventory")
    }

    @Test func imageOnlyResultWaitsForSeparateToolResultMessages() throws {
        let wire = try messages([
            calls(["image", "failed"]),
            result("image", [.image(base64: "cGljdHVyZQ==", mediaType: "image/png")]),
            result("failed", [.text("Missing media")], isError: true),
            AgentRequestMessage(role: .assistant, content: [.content(.text("Reviewed"))]),
        ])

        #expect(wire.compactMap { $0["role"] as? String } == ["assistant", "tool", "tool", "user", "assistant"])
        let attachment = try #require(wire.first { $0["role"] as? String == "user" }?["content"] as? [[String: Any]])
        #expect(imageURLs(attachment) == ["data:image/png;base64,cGljdHVyZQ=="])
        #expect((attachment.first?["text"] as? String)?.contains("image") == true)
        #expect(wire.first { $0["tool_call_id"] as? String == "failed" }?["content"] as? String == "Tool error: Missing media")
    }

    @Test func historyReplayKeepsImagesWithTheirToolCalls() throws {
        let history = [
            AgentMessage(role: .assistant, blocks: [.toolUse(id: "first", name: "inspect_media", inputJSON: "{}")]),
            AgentMessage(role: .user, blocks: [.toolResult(
                toolUseId: "first", content: [.image(base64: "YQ==", mediaType: "image/png")], isError: false
            )]),
            AgentMessage(role: .assistant, blocks: [.toolUse(id: "second", name: "inspect_timeline", inputJSON: "{}")]),
            AgentMessage(role: .user, blocks: [.toolResult(
                toolUseId: "second", content: [.image(base64: "Yg==", mediaType: "image/jpeg")], isError: true
            )]),
        ]
        let restored = try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(history))
        let wire = try messages(restored.map {
            AgentRequestMessage(role: $0.role == .assistant ? .assistant : .user, content: $0.blocks.map(AgentRequestBlock.content))
        })
        let attachments = wire.filter { $0["role"] as? String == "user" }
        #expect(attachments.count == 2)
        let first = try #require(attachments.first?["content"] as? [[String: Any]])
        let second = try #require(attachments.last?["content"] as? [[String: Any]])
        #expect((first.first?["text"] as? String)?.contains("first") == true)
        #expect((second.first?["text"] as? String)?.contains("second") == true)
        #expect(imageURLs(first) == ["data:image/png;base64,YQ=="])
        #expect(imageURLs(second) == ["data:image/jpeg;base64,Yg=="])
        #expect((second.first?["text"] as? String)?.contains("Tool error") == true)
    }

    @Test func imagesFromDifferentCallsKeepTheirBoundariesInOneAttachment() throws {
        let wire = try messages([
            calls(["first", "second"]),
            result("first", [.image(base64: "YQ==", mediaType: "image/png")]),
            result("second", [.image(base64: "Yg==", mediaType: "image/jpeg")]),
        ])
        #expect(wire.compactMap { $0["role"] as? String } == ["assistant", "tool", "tool", "user"])
        let attachment = try #require(wire.last?["content"] as? [[String: Any]])
        #expect(attachment.compactMap { $0["type"] as? String } == ["text", "image_url", "text", "image_url"])
        let labels = attachment.compactMap { $0["text"] as? String }
        #expect(labels.first?.contains("first") == true)
        #expect(labels.last?.contains("second") == true)
        #expect(imageURLs(attachment) == ["data:image/png;base64,YQ==", "data:image/jpeg;base64,Yg=="])
    }

    @Test func userImagesKeepSurroundingTextOrder() throws {
        let wire = try messages([AgentRequestMessage(role: .user, content: [
            .content(.text("Before")),
            .image(base64: "YQ==", mediaType: "image/png"),
            .content(.text("After")),
        ])])
        let content = try #require(wire.first?["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["text", "image_url", "text"])
        #expect(content.first?["text"] as? String == "Before")
        #expect(content.last?["text"] as? String == "After")
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    @MainActor
    func declaredImageSupportPersistsWithTheSelectedModel(supportsImages: Bool?) async throws {
        let suite = "CustomEndpointVisionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = await CustomModelStore.upsert(
            id: nil, name: "Test model", baseURL: "http://localhost:11434/v1", modelID: "test-model",
            key: .unchanged, supportsImages: supportsImages, defaults: defaults
        )
        guard case .saved = saved else {
            Issue.record("Model save failed: \(saved)")
            return
        }
        let model = try #require(CustomModelStore.selected(defaults: defaults))
        #expect(model.supportsImages == supportsImages)
        let settings = AgentRunSettings(model: .custom, reasoningEffort: .medium, custom: model)
        #expect(settings.supportsImages == supportsImages)
    }

    private func calls(_ ids: [String]) -> AgentRequestMessage {
        AgentRequestMessage(role: .assistant, content: ids.map {
            .content(.toolUse(id: $0, name: "inspect_media", inputJSON: "{}"))
        })
    }

    private func result(_ id: String, _ content: [ToolResult.Block], isError: Bool = false) -> AgentRequestMessage {
        AgentRequestMessage(role: .user, content: [.content(.toolResult(toolUseId: id, content: content, isError: isError))])
    }

    private func messages(_ input: [AgentRequestMessage]) throws -> [[String: Any]] {
        let body = OpenAIChatCompletionsRequestBody.build(modelID: "vision-model", system: "", tools: [], messages: input)
        return try #require(body["messages"] as? [[String: Any]])
    }

    private func imageURLs(_ parts: [[String: Any]]) -> [String] {
        parts.compactMap { ($0["image_url"] as? [String: String])?["url"] }
    }
}
