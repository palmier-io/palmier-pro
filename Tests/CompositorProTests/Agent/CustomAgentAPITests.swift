import Foundation
import Testing
@testable import CompositorPro

@Suite("Custom agent API selection")
@MainActor
struct CustomAgentAPITests {
    @Test func savingAndSwitchingAPIsPreservesModelIdentityAndSelection() throws {
        let suite = "CustomAgentAPITests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = CustomModelStore.upsert(id: nil, name: "Gateway", baseURL: "https://example.com/v1",
                                            modelID: "gpt-6.1-sol", api: .responses, defaults: defaults)
        guard case .saved(let id) = result else { Issue.record("Expected a saved model"); return }
        let responses = try #require(CustomModelStore.selected(defaults: defaults))
        #expect(responses.id == id)
        #expect(responses.selectedAPI == .responses)
        #expect(responses.requestURL.absoluteString == "https://example.com/v1/responses")
        let service = AgentService(userDefaults: defaults)
        service.selectCustomModel(id)
        service.model = .custom
        let captured = service.snapshotRunSettings()
        #expect(captured.streamProvider == .openAI)
        #expect(captured.custom?.selectedAPI == .responses)
        _ = CustomModelStore.upsert(id: id, name: "Gateway", baseURL: "https://example.com/v1",
                                    modelID: "gpt-6.1-sol", api: .chatCompletions, defaults: defaults)
        let chat = try #require(CustomModelStore.selected(defaults: defaults))
        #expect(chat.id == id)
        #expect(chat.requestURL.absoluteString == "https://example.com/v1/chat/completions")
        #expect(captured.custom?.selectedAPI == .responses)
        #expect(CustomModelStore.load(defaults: defaults).count == 1)
    }

    @Test func modelsWithoutAnExplicitAPIKeepChatCompletions() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "name": "Local", "baseURL": "http://localhost:11434/v1", "modelID": "qwen",
        ])
        let model = try JSONDecoder().decode(CustomAgentModel.self, from: data)
        #expect(model.selectedAPI == .chatCompletions)
        #expect(model.requestURL.path == "/v1/chat/completions")
    }
}
