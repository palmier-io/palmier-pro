import Foundation
import Testing
@testable import CompositorPro

@Suite("Custom agent endpoint")
struct CustomAgentModelTests {

    @Test func baseURLNormalizationAcceptsTheFormsPeoplePaste() {
        #expect(CustomModelStore.normalizedBaseURL("http://localhost:11434")?
            .absoluteString == "http://localhost:11434/v1")
        #expect(CustomModelStore.normalizedBaseURL("http://localhost:11434/")?
            .absoluteString == "http://localhost:11434/v1")
        #expect(CustomModelStore.normalizedBaseURL("http://localhost:11434/v1")?
            .absoluteString == "http://localhost:11434/v1")
        #expect(CustomModelStore.normalizedBaseURL("https://api.example.com/openai/v1")?
            .absoluteString == "https://api.example.com/openai/v1")
        #expect(CustomModelStore.normalizedBaseURL("ftp://example.com") == nil)
        #expect(CustomModelStore.normalizedBaseURL("not a url") == nil)
    }

    @Test func onlyLoopbackHostsMayRunWithoutACredential() throws {
        func endpoint(_ raw: String) throws -> CustomAgentModel {
            CustomAgentModel(
                baseURL: try #require(CustomModelStore.normalizedBaseURL(raw)),
                modelID: "m")
        }
        #expect(try endpoint("http://localhost:11434/v1").allowsMissingAPIKey)
        #expect(try endpoint("http://127.0.0.1:1234/v1").allowsMissingAPIKey)
        #expect(try endpoint("http://[::1]:1234/v1").allowsMissingAPIKey)
        #expect(try endpoint("https://api.example.com/v1").allowsMissingAPIKey == false)
    }

    @Test func chatCompletionsURLAppendsToTheVersionedBase() throws {
        let base = try #require(CustomModelStore.normalizedBaseURL("http://localhost:11434"))
        let endpoint = CustomAgentModel(baseURL: base, modelID: "qwen3:8b")
        #expect(endpoint.chatCompletionsURL.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func configuredEndpointRoutesDirectAndMissingOneIsUnavailable() throws {
        let local = CustomAgentModel(
            baseURL: try #require(CustomModelStore.normalizedBaseURL("http://localhost:11434")),
            modelID: "qwen3:8b")
        let remote = CustomAgentModel(
            baseURL: try #require(CustomModelStore.normalizedBaseURL("https://api.example.com/v1")),
            modelID: "some-model")

        #expect(AgentRouting.route(model: .custom, credentials: AgentCredentialSnapshot(),
                                  hasHostedCredits: true, hasPaidPlan: true, custom: local) == .direct)
        #expect(AgentRouting.route(model: .custom, credentials: AgentCredentialSnapshot(),
                                  hasHostedCredits: true, hasPaidPlan: true,
                                  custom: remote, customKey: "") == .unavailable)
        #expect(AgentRouting.route(model: .custom, credentials: AgentCredentialSnapshot(),
                                  hasHostedCredits: false, hasPaidPlan: false,
                                  custom: remote, customKey: "key") == .direct)
        #expect(AgentRouting.route(model: .custom, credentials: AgentCredentialSnapshot(),
                                  hasHostedCredits: false, hasPaidPlan: false, custom: nil) == .unavailable)
    }

    @Test func runSettingsCarryTheEndpointOnlyForTheCustomModel() throws {
        let endpoint = CustomAgentModel(
            baseURL: try #require(CustomModelStore.normalizedBaseURL("http://localhost:11434/v1")),
            modelID: "qwen3:8b")
        #expect(AgentRunSettings(model: .custom, reasoningEffort: .none, custom: endpoint).custom == endpoint)
        #expect(AgentRunSettings(model: .terra, reasoningEffort: .medium, custom: endpoint).custom == nil)
    }

    @Test func requestBodyUsesTheConfiguredModelIDAndOmitsUnsupportedFields() throws {
        let body = chatBody(modelID: "qwen3-coder:30b")
        #expect(body["model"] as? String == "qwen3-coder:30b")
        #expect(body["stream"] as? Bool == true)
        // A fixed 64k budget and reasoning knobs are rejected by small local servers.
        #expect(body["max_tokens"] == nil)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["store"] == nil)
    }

    @Test func requestBodyMapsToolsImagesAndToolResults() throws {
        let body = OpenAIChatCompletionsRequestBody.build(
            modelID: "m",
            system: "Instructions",
            tools: [AgentToolSchema(name: "inspect_timeline", description: "Inspect",
                                    inputSchema: ["type": "object"])],
            messages: [
                AgentRequestMessage(role: .user, content: [
                    .content(.text("Look")),
                    .image(base64: "aGVsbG8=", mediaType: "image/png"),
                ]),
                AgentRequestMessage(role: .assistant, content: [
                    .content(.thinking(text: "hidden", signature: "sig")),
                    .content(.text("Calling")),
                    .content(.toolUse(id: "call_1", name: "inspect_timeline", inputJSON: "{\"b\":2,\"a\":1}")),
                ]),
                AgentRequestMessage(role: .user, content: [
                    .content(.toolResult(toolUseId: "call_1", content: [.text("Done")], isError: false)),
                ]),
            ]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect(try #require(messages.first?["content"] as? String) == "Instructions")

        let user = try #require(messages.first { $0["role"] as? String == "user" })
        let parts = try #require(user["content"] as? [[String: Any]])
        #expect(parts.contains { $0["type"] as? String == "text" })
        #expect(parts.contains { $0["type"] as? String == "image_url" })

        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(assistant["content"] as? String == "Calling")
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let function = try #require(calls.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "inspect_timeline")
        #expect(function["arguments"] as? String == "{\"a\":1,\"b\":2}")

        let tool = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(tool["tool_call_id"] as? String == "call_1")
        #expect(tool["content"] as? String == "Done")

        #expect(try #require((tools.first?["function"] as? [String: Any])?["name"] as? String)
            == "inspect_timeline")
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try #require(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(json.contains("data:image/png;base64,aGVsbG8="))
        #expect(!json.contains("hidden"))
    }

    @Test func requestBodyPreservesMultimodalToolResultImages() throws {
        let body = OpenAIChatCompletionsRequestBody.build(
            modelID: "custom-vision",
            system: "System prompt",
            tools: [AgentToolSchema(name: "inspect_media", description: "Inspect", inputSchema: ["type": "object"])],
            messages: [
                AgentRequestMessage(role: .assistant, content: [
                    .content(.toolUse(id: "call_img", name: "inspect_media", inputJSON: #"{"mediaRef":"asset-1"}"#)),
                ]),
                AgentRequestMessage(role: .user, content: [
                    .content(.toolResult(
                        toolUseId: "call_img",
                        content: [
                            .image(base64: "aW1nZGF0YQ==", mediaType: "image/png"),
                            .text(#"{"mediaRef":"asset-1","frameTimestamps":[0.5]}"#),
                        ],
                        isError: false
                    )),
                ]),
            ]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.compactMap { $0["role"] as? String } == ["system", "assistant", "tool", "user"])

        let toolMessage = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "call_img")
        #expect((toolMessage["content"] as? String)?.contains("includes images") == true)

        let userMessage = try #require(messages.first { $0["role"] as? String == "user" })
        let parts = try #require(userMessage["content"] as? [[String: Any]])
        let texts = parts.compactMap { $0["text"] as? String }
        #expect(texts.contains { $0.contains("call_img") })
        #expect(texts.contains { $0.contains("frameTimestamps") })
        let imageUrls = parts.compactMap { ($0["image_url"] as? [String: String])?["url"] }
        #expect(imageUrls == ["data:image/png;base64,aW1nZGF0YQ=="])
    }

    @Test func toolResultErrorsAreLabelledForTheModel() throws {
        let body = OpenAIChatCompletionsRequestBody.build(
            modelID: "m",
            system: "",
            tools: [],
            messages: [AgentRequestMessage(role: .user, content: [
                .content(.toolResult(toolUseId: "c1", content: [.text("bad path")], isError: true)),
            ])]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(try #require(messages.first?["content"] as? String) == "Tool error: bad path")
    }

    /// The live provider closes with a usage-only chunk that repeats `finish_reason` but
    /// carries no delta. It must not re-terminate the turn or drop the pending calls.
    @Test func parserHandlesUsageOnlyTrailingChunkWithRepeatedFinishReason() throws {
        var parser = OpenAIChatCompletionsStreamParser()
        #expect(try parser.consume(line: #"data: {"id":"g1","choices":[{"index":0,"delta":{"content":null,"role":"assistant","tool_calls":[{"index":0,"id":"698ce22d","type":"function","function":{"name":"get_timeline","arguments":""}}]},"finish_reason":null}]}"#) == [.activity(.preparingTool("get_timeline"))])
        #expect(try parser.consume(line: #"data: {"id":"g1","choices":[{"index":0,"delta":{"content":null,"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]},"finish_reason":null}]}"#) == [])
        // Provider sometimes sends finish_reason twice: once with the delta, once with usage.
        #expect(try parser.consume(line: #"data: {"id":"g1","choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":"tool_calls"}]}"#)
            == [.toolUseComplete(id: "698ce22d", name: "get_timeline", inputJSON: "{}"),
                .messageStop(stopReason: .toolUse)])
        // The trailing usage chunk must not emit a second stop reason that overwrites .toolUse.
        #expect(try parser.consume(line: #"data: {"id":"g1","choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":33436,"completion_tokens":54}}"#) == [])
        try parser.finish()
    }

    @Test func parserReassemblesFragmentedToolCallsAndStopReason() throws {
        var parser = OpenAIChatCompletionsStreamParser()
        #expect(try parser.consume(line: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#)
            == [.textDelta("Hi")])
        #expect(try parser.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"think"}}]}"#)
            == [.reasoningSummaryDelta("think")])
        #expect(try parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"inspect_timeline","arguments":"{\"a\":"}}]}}]}"#) == [.activity(.preparingTool("inspect_timeline"))])
        #expect(try parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]},"finish_reason":"tool_calls"}]}"#)
            == [.toolUseComplete(id: "call_1", name: "inspect_timeline", inputJSON: "{\"a\":1}"),
                .messageStop(stopReason: .toolUse)])
        try parser.finish()
    }

    @Test func parserKeepsParallelToolCallsApart() throws {
        var parser = OpenAIChatCompletionsStreamParser()
        _ = try parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{}"}}]}}]}"#)
        _ = try parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{}"}}]}}]}"#)
        let events = try parser.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        #expect(events == [
            .toolUseComplete(id: "a", name: "first", inputJSON: "{}"),
            .toolUseComplete(id: "b", name: "second", inputJSON: "{}"),
            .messageStop(stopReason: .toolUse),
        ])
    }

    @Test func parserTerminatesOnDoneAndClassifiesFinishReasons() throws {
        var parser = OpenAIChatCompletionsStreamParser()
        #expect(try parser.consume(line: #"data: {"choices":[{"delta":{"content":"x"},"finish_reason":"length"}]}"#)
            == [.textDelta("x"), .messageStop(stopReason: .maxTokens)])
        try parser.finish()

        var done = OpenAIChatCompletionsStreamParser()
        #expect(try done.consume(line: "data: [DONE]") == [.messageStop(stopReason: .endTurn)])
        try done.finish()

        var filtered = OpenAIChatCompletionsStreamParser()
        #expect(try filtered.consume(line: #"data: {"choices":[{"finish_reason":"content_filter"}]}"#)
            == [.messageStop(stopReason: .refusal)])
    }

    /// A gateway can close with a generic reason, or none at all, after streaming tool-call
    /// deltas. The accumulated calls decide the stop reason, or the agent loop exits early
    /// and the model silently stops acting.
    @Test func parserReportsToolUseWhenTheGatewayOmitsTheToolCallsReason() throws {
        var generic = OpenAIChatCompletionsStreamParser()
        _ = try generic.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_timeline","arguments":"{}"}}]}}]}"#)
        #expect(try generic.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            == [.toolUseComplete(id: "call_1", name: "get_timeline", inputJSON: "{}"),
                .messageStop(stopReason: .toolUse)])

        var noReason = OpenAIChatCompletionsStreamParser()
        _ = try noReason.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","function":{"name":"get_transcript","arguments":"{}"}}]}}]}"#)
        #expect(try noReason.consume(line: "data: [DONE]")
            == [.toolUseComplete(id: "call_2", name: "get_transcript", inputJSON: "{}"),
                .messageStop(stopReason: .toolUse)])
    }

    @Test func parserSurfacesErrorsAndMissingTerminalEvent() {
        #expect(throws: AgentClientTransportError.self) {
            var parser = OpenAIChatCompletionsStreamParser()
            _ = try parser.consume(line: #"data: {"error":{"message":"model not found"}}"#)
        }
        #expect(throws: AgentClientTransportError.self) {
            try OpenAIChatCompletionsStreamParser().finish()
        }
    }

    private func chatBody(modelID: String) -> [String: Any] {
        AgentRunSettings(
            model: .custom,
            reasoningEffort: .none,
            custom: CustomAgentModel(
                baseURL: URL(string: "http://localhost:11434/v1")!, modelID: modelID)
        ).requestBody(system: "Instructions", tools: [], messages: [])
    }
}

@Suite("Custom agent endpoint persistence")
@MainActor
struct CustomAgentModelPersistenceTests {

    @Test func modelsRoundTripThroughDefaultsAndValidate() async throws {
        try await withDefaults { defaults in
            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "", baseURL: "", modelID: "m",
                                                         defaults: defaults)) != nil)
            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "", baseURL: "http://localhost:11434",
                                           modelID: "  ", defaults: defaults)) != nil)
            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "", baseURL: "localhost:11434",
                                           modelID: "m", defaults: defaults)) != nil)

            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "Local", baseURL: "http://localhost:11434/",
                                           modelID: "qwen3:8b", defaults: defaults)) == nil)
            let loaded = try #require(CustomModelStore.load(defaults: defaults).first)
            #expect(loaded.baseURL.absoluteString == "http://localhost:11434/v1")
            #expect(loaded.modelID == "qwen3:8b")
            // The model id is the identity and the wire value; the nickname is a subtitle.
            #expect(loaded.displayTitle == "qwen3:8b")
            #expect(loaded.displaySubtitle == "Local")

            CustomModelStore.remove(id: loaded.id, defaults: defaults)
            #expect(CustomModelStore.load(defaults: defaults).isEmpty)
        }
    }

    @Test func severalModelsCoexistAndEachKeepsItsOwnSelection() async throws {
        try await withDefaults { defaults in
            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "Local", baseURL: "http://localhost:11434",
                                           modelID: "qwen3:8b", defaults: defaults)) == nil)
            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "Cloud", baseURL: "https://openrouter.ai/api/v1",
                                           modelID: "stealth/space-bunny-alpha",
                                           defaults: defaults)) == nil)
            let models = CustomModelStore.load(defaults: defaults)
            #expect(models.count == 2)
            #expect(models.map(\.modelID).contains("qwen3:8b"))
            #expect(models.map(\.modelID).contains("stealth/space-bunny-alpha"))

            let service = AgentService(userDefaults: defaults)
            #expect(service.customModels.count == 2)
            #expect(service.builtInModels.contains(.custom) == false)

            service.selectCustomModel(try #require(models.last).id)
            service.model = .custom
            #expect(service.snapshotRunSettings().custom?.modelID == "stealth/space-bunny-alpha")
            #expect(service.modelTitle(.custom) == "stealth/space-bunny-alpha")
        }
    }

    @Test func keyAccountsAreDistinctPerModel() throws {
        let first = UUID()
        let second = UUID()
        #expect(CustomModelStore.keyAccount(for: first) != CustomModelStore.keyAccount(for: second))
    }

    /// Regression: saving a model used to hand the credential write a live reference to the key
    /// field, which the form reset had already emptied. The key was therefore deleted the moment
    /// it was saved, which in turn left every remote custom model permanently unroutable.
    @Test func savingWithAnUntouchedKeyFieldKeepsTheStoredKey() async throws {
        try await withDefaults { defaults in
            let added = await CustomModelStore.upsert(
                id: nil, name: "Gateway", baseURL: "https://api.example.com/v1",
                modelID: "some-model", key: .set("sk-first"), defaults: defaults
            )
            let id = try #require(Self.savedID(added))
            #expect(await CustomModelStore.loadKey(for: id) == "sk-first")

            // Re-saving the model without touching the key must leave the key alone.
            let resaved = await CustomModelStore.upsert(
                id: id, name: "Gateway renamed", baseURL: "https://api.example.com/v1",
                modelID: "some-model", key: .unchanged, defaults: defaults
            )
            #expect(Self.savedID(resaved) == id)
            #expect(await CustomModelStore.loadKey(for: id) == "sk-first")

            let replacement = try #require(CustomModelStore.load(defaults: defaults).first)
            #expect(replacement.name == "Gateway renamed")

            await CustomModelStore.setKey(nil, for: id)
        }
    }

    @Test func emptyingTheKeyFieldExplicitlyRemovesTheKey() async throws {
        try await withDefaults { defaults in
            let added = await CustomModelStore.upsert(
                id: nil, name: "Gateway", baseURL: "https://api.example.com/v1",
                modelID: "some-model", key: .set("sk-first"), defaults: defaults
            )
            let id = try #require(Self.savedID(added))
            #expect(await CustomModelStore.loadKey(for: id) == "sk-first")

            _ = await CustomModelStore.upsert(
                id: id, name: "Gateway", baseURL: "https://api.example.com/v1",
                modelID: "some-model", key: .clear, defaults: defaults
            )
            #expect(await CustomModelStore.loadKey(for: id) == "")
        }
    }

    /// A failed save must not touch the credential, so a typo in the URL cannot cost the user
    /// the key they already had.
    @Test func aRejectedSaveLeavesTheKeyAlone() async throws {
        try await withDefaults { defaults in
            let added = await CustomModelStore.upsert(
                id: nil, name: "Gateway", baseURL: "https://api.example.com/v1",
                modelID: "some-model", key: .set("sk-first"), defaults: defaults
            )
            let id = try #require(Self.savedID(added))

            let rejected = await CustomModelStore.upsert(
                id: id, name: "Gateway", baseURL: "not-a-url",
                modelID: "some-model", key: .set("sk-second"), defaults: defaults
            )
            #expect(Self.failure(rejected) != nil)
            #expect(await CustomModelStore.loadKey(for: id) == "sk-first")

            await CustomModelStore.setKey(nil, for: id)
        }
    }

    /// The user-visible consequence: with a key on file, a remote custom model must route.
    @Test func aRemoteCustomModelWithAStoredKeyIsSelectable() async throws {
        try await withDefaults { defaults in
            let added = await CustomModelStore.upsert(
                id: nil, name: "Gateway", baseURL: "https://api.example.com/v1",
                modelID: "some-model", key: .set("sk-first"), defaults: defaults
            )
            _ = try #require(Self.savedID(added))

            let service = AgentService(userDefaults: defaults)
            service.model = .custom
            for _ in 0..<50 where service.route != .direct {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(service.canSelectModel(.custom))
            #expect(service.route == .direct)

            let models = CustomModelStore.load(defaults: defaults)
            for model in models {
                await CustomModelStore.setKey(nil, for: model.id)
            }
        }
    }

    private static func savedID(_ result: CustomModelSaveResult) -> UUID? {
        if case .saved(let id) = result { return id }
        return nil
    }

    @Test func customModelIsOfferedOnlyWhileAModelExists() async throws {
        try await withDefaults { defaults in
            let service = AgentService(userDefaults: defaults)
            #expect(service.availableModels.contains(.custom) == false)
            #expect(service.canSelectModel(.custom) == false)

            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "", baseURL: "http://localhost:11434",
                                           modelID: "qwen3:8b", defaults: defaults)) == nil)
            service.updateCustomEndpoint(nil)
            #expect(service.availableModels.contains(.custom))
            #expect(service.canSelectModel(.custom))
            #expect(service.modelTitle(.custom) == "qwen3:8b")
            #expect(service.modelTitle(.terra) == "GPT-5.6 Terra")

            service.model = .custom
            #expect(service.snapshotRunSettings().custom?.modelID == "qwen3:8b")

            for model in CustomModelStore.load(defaults: defaults) {
                CustomModelStore.remove(id: model.id, defaults: defaults)
            }
            service.updateCustomEndpoint(nil)
            #expect(service.model == .defaultModel)
            #expect(service.availableModels.contains(.custom) == false)
        }
    }

    @Test func aSavedCustomModelFallsBackWhenNoModelRemains() async throws {
        try await withDefaults { defaults in
            #expect(Self.failure(CustomModelStore.upsert(id: nil, name: "", baseURL: "http://localhost:11434",
                                           modelID: "qwen3:8b", defaults: defaults)) == nil)
            _ = AgentService(userDefaults: defaults).model
            defaults.set("custom", forKey: "agentModel")
            for model in CustomModelStore.load(defaults: defaults) {
                CustomModelStore.remove(id: model.id, defaults: defaults)
            }

            let reopened = AgentService(userDefaults: defaults)
            #expect(reopened.model == .defaultModel)
        }
    }

    private static func failure(_ result: CustomModelSaveResult) -> String? {
        if case .failed(let message) = result { return message }
        return nil
    }

    @MainActor
    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suiteName = "CustomAgentModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }
}
