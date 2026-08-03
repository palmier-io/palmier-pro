import Foundation
import Testing
@testable import PalmierPro

@Suite("Agent providers")
struct AgentProviderTests {
    @Test func modelCatalogContainsExactlySupportedModels() {
        #expect(AgentModel.allCases.map { [$0.rawValue, $0.displayName] } == [
            ["claude-sonnet-5", "Sonnet 5"],
            ["claude-opus-5", "Opus 5"],
            ["claude-fable-5", "Fable 5"],
            ["gpt-5.6-luna", "GPT-5.6 Luna"],
            ["gpt-5.6-terra", "GPT-5.6 Terra"],
            ["gpt-5.6-sol", "GPT-5.6 Sol"],
        ])
        #expect(AgentModel.allCases.allSatisfy { $0.maxOutputTokens == 64_000 })
        #expect(AgentModel.defaultModel == .terra)
        #expect(AgentModel.persisted("claude-opus-4-8") == .opus5)
        #expect(AgentModel.allCases.map(\.provider) == [
            .anthropic, .anthropic, .anthropic, .openAI, .openAI, .openAI,
        ])
        #expect(AgentModel.allCases.filter(\.requiresPaidHostedPlan) == [.fable5, .sol])
        let anthropicEfforts: [AgentReasoningEffort] = [.low, .medium, .high, .xHigh, .max]
        let openAIEfforts = AgentReasoningEffort.allCases
        #expect(AgentModel.allCases.filter { $0.provider == .anthropic }
            .allSatisfy { $0.supportedReasoningEfforts == anthropicEfforts })
        #expect(AgentModel.allCases.filter { $0.provider == .openAI }
            .allSatisfy { $0.supportedReasoningEfforts == openAIEfforts })
        #expect(openAIEfforts == [.none, .minimal, .low, .medium, .high, .xHigh, .max])
    }

    @Test func routingUsesOnlyTheSelectedProvidersKey() {
        #expect(route(.sonnet5, key: .openAI) == .unavailable)
        #expect(route(.luna, key: .anthropic) == .unavailable)
        #expect(route(.fable5, key: .anthropic, hasCredits: true) == .direct)
        #expect(route(.terra, hasCredits: true) == .hosted)
        #expect(route(.fable5, hasCredits: true) == .unavailable)
        #expect(route(.sol, hasCredits: true, isPaid: true) == .hosted)
    }

    @Test func defaultBaseURLsMatchProviderChatEndpoints() {
        #expect(AgentProvider.anthropic.defaultBaseURLString == "https://api.anthropic.com")
        #expect(AgentProvider.openAI.defaultBaseURLString == "https://api.openai.com/v1")
        #expect(
            AgentProvider.anthropic.chatEndpoint(baseURLString: nil).absoluteString
                == "https://api.anthropic.com/v1/messages"
        )
        #expect(
            AgentProvider.openAI.chatEndpoint(baseURLString: nil).absoluteString
                == "https://api.openai.com/v1/responses"
        )
    }

    @Test(arguments: [
        ("https://proxy.example", "https://proxy.example/v1/messages"),
        ("https://proxy.example/", "https://proxy.example/v1/messages"),
        ("", "https://api.anthropic.com/v1/messages"),
        ("   ", "https://api.anthropic.com/v1/messages"),
        ("not a url", "https://api.anthropic.com/v1/messages"),
    ])
    func anthropicBaseURLResolution(base: String, expected: String) {
        #expect(AgentProvider.anthropic.chatEndpoint(baseURLString: base).absoluteString == expected)
    }

    @Test(arguments: [
        ("https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/responses"),
        ("https://openrouter.ai/api/v1/", "https://openrouter.ai/api/v1/responses"),
        ("", "https://api.openai.com/v1/responses"),
        ("bad", "https://api.openai.com/v1/responses"),
    ])
    func openAIBaseURLResolution(base: String, expected: String) {
        #expect(AgentProvider.openAI.chatEndpoint(baseURLString: base).absoluteString == expected)
    }

    @Test func anthropicReasoningUsesMediumDefaultAndExplicitEffort() throws {
        for model in AgentModel.allCases.filter({ $0.provider == .anthropic }) {
            let body = AnthropicRequestBody.build(
                model: model, system: "Instructions", tools: [], messages: [])
            let outputConfig = try #require(body["output_config"] as? [String: String])
            let thinking = try #require(body["thinking"] as? [String: String])
            #expect(outputConfig["effort"] == "medium")
            #expect(thinking == ["type": "adaptive", "display": "summarized"])
            #expect(body["max_tokens"] as? Int == 64_000)
        }
        let explicit = AnthropicRequestBody.build(
            model: .fable5, reasoningEffort: .xHigh,
            system: "Instructions", tools: [], messages: [])
        let outputConfig = try #require(explicit["output_config"] as? [String: String])
        #expect(outputConfig["effort"] == "xhigh")
    }

    @Test func openAIRequestMapsConversationAndFunctionTools() throws {
        let messages = [
            AgentRequestMessage(role: .user, content: [
                .content(.text("Inspect this")),
                .image(base64: "aGVsbG8=", mediaType: "image/png")
            ]),
            AgentRequestMessage(role: .assistant, content: [
                reasoning("Checked context", encrypted: "encrypted-luna", id: "rs_1", model: .luna),
                reasoning("Wrong model", encrypted: "encrypted-terra", id: "rs_2", model: .terra),
                .content(.text("Calling a tool")),
                .content(.toolUse(id: "call_1", name: "inspect_timeline", inputJSON: "{\"b\":2,\"a\":1}"))
            ]),
            AgentRequestMessage(role: .user, content: [
                .content(.toolResult(
                    toolUseId: "call_1",
                    content: [.text("Done"), .image(base64: "aW1hZ2U=", mediaType: "image/jpeg")],
                    isError: false))
            ]),
        ]
        let body = openAIBody(
            tools: [AgentToolSchema(
                name: "inspect_timeline", description: "Inspect the timeline",
                inputSchema: ["type": "object"])],
            messages: messages
        )
        let items = try #require(body["input"] as? [[String: Any]])
        let tools = try #require(body["tools"] as? [[String: Any]])
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let json = try #require(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_output_tokens"] as? Int == 64_000)
        #expect(body["instructions"] as? String == "Instructions")
        #expect(tools.first?["type"] as? String == "function")
        #expect(items.contains { $0["type"] as? String == "function_call" })
        #expect(items.contains { $0["type"] as? String == "function_call_output" })
        #expect(json.contains("data:image/png;base64,aGVsbG8="))
        #expect(json.contains("data:image/jpeg;base64,aW1hZ2U="))
        #expect(json.contains("encrypted-luna"))
        #expect(!json.contains("encrypted-terra"))
    }

    @Test func openAIReasoningUsesMediumDefaultAndExplicitEffortWithoutMode() throws {
        for model in AgentModel.allCases.filter({ $0.provider == .openAI }) {
            let body = openAIBody(model)
            let reasoning = try #require(body["reasoning"] as? [String: Any])
            #expect(reasoning["summary"] as? String == "auto")
            #expect(reasoning["effort"] as? String == "medium")
            #expect(reasoning["mode"] == nil)
        }
        let body = OpenAIRequestBody.build(
            model: .sol, reasoningEffort: .max,
            system: "Instructions", tools: [], messages: [])
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "max")
    }

    @Test func openAIReasoningReplayIncludesRequiredEmptySummary() throws {
        let assistant = AgentRequestMessage(
            role: .assistant,
            content: [reasoning("", encrypted: "opaque", id: "rs_empty", model: .sol)]
        )
        let body = openAIBody(.sol, messages: [assistant])
        let items = try #require(body["input"] as? [[String: Any]])
        let reasoning = try #require(items.first { $0["type"] as? String == "reasoning" })
        let summary = try #require(reasoning["summary"] as? [Any])
        #expect(summary.isEmpty)
    }

    @Test func openAIParserUsesCompleteItemsAndTerminalResponse() throws {
        var parser = OpenAIStreamParser()
        #expect(try parser.consume(line: #"data: {"type":"response.reasoning_summary_text.delta","delta":"Checking"}"#) == [.reasoningSummaryDelta("Checking")])
        #expect(try parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"Done"}"#) == [.textDelta("Done")])
        let toolUse = AgentStreamEvent.toolUseComplete(
            id: "call_1", name: "inspect_timeline", inputJSON: "{\"timelineId\":\"main\"}")
        #expect(try parser.consume(line: #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"inspect_timeline","arguments":"{\"timelineId\":\"main\"}"}}"#) == [toolUse])
        let reasoning = AgentStreamEvent.reasoningComplete(
            itemID: "rs_1", summary: "Checking", encryptedContent: "opaque")
        #expect(try parser.consume(line: #"data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Checking"}],"encrypted_content":"opaque"}}"#) == [reasoning])
        #expect(try parser.consume(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call"}]}}"#) == [.messageStop(stopReason: .toolUse)])
        #expect(try parser.finish().isEmpty)
    }

    @Test func openAIParserTreatsStreamedFunctionCallAsToolUseEvenWhenCompletedOutputOmitsIt() throws {
        var parser = OpenAIStreamParser()
        let toolUse = AgentStreamEvent.toolUseComplete(
            id: "call_1", name: "get_timeline", inputJSON: "{\"startFrame\":0,\"endFrame\":0}")
        #expect(try parser.consume(line: #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"get_timeline","arguments":"{\"startFrame\":0,\"endFrame\":0}"}}"#) == [toolUse])
        #expect(try parser.consume(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"#) == [.messageStop(stopReason: .toolUse)])
        #expect(try parser.finish().isEmpty)
    }

    @Test func openAIParserSynthesizesToolUseStopWhenStreamEndsAfterFunctionCall() throws {
        var parser = OpenAIStreamParser()
        let toolUse = AgentStreamEvent.toolUseComplete(
            id: "call_1", name: "get_timeline", inputJSON: "{}")
        #expect(try parser.consume(line: #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"get_timeline","arguments":"{}"}}"#) == [toolUse])
        #expect(try parser.finish() == [.messageStop(stopReason: .toolUse)])
    }

    @Test func openAIParserClassifiesRefusalFromTerminalResponse() throws {
        var parser = OpenAIStreamParser()
        #expect(try parser.consume(line: #"data: {"type":"response.refusal.delta","delta":"No"}"#) == [.textDelta("No")])
        #expect(try parser.consume(line: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}}"#) == [.messageStop(stopReason: .refusal)])
        #expect(try parser.finish().isEmpty)
    }

    @Test func openAIParserSurfacesFailureCancellationAndMissingTerminalEvent() {
        #expect(throws: AgentClientTransportError.self) {
            var parser = OpenAIStreamParser()
            _ = try parser.consume(line: #"data: {"type":"response.failed","response":{"error":{"message":"Failed"}}}"#)
        }
        #expect(throws: CancellationError.self) {
            var parser = OpenAIStreamParser()
            _ = try parser.consume(line: #"data: {"type":"response.cancelled","response":{}}"#)
        }
        #expect(throws: AgentClientTransportError.self) {
            var parser = OpenAIStreamParser()
            _ = try parser.finish()
        }
    }

    private func route(
        _ model: AgentModel,
        key: AgentProvider? = nil, hasCredits: Bool = false, isPaid: Bool = false
    ) -> AgentRoute {
        AgentRouting.route(
            model: model,
            credentials: AgentCredentialSnapshot(key.map { [$0: "key"] } ?? [:]),
            hasHostedCredits: hasCredits, hasPaidPlan: isPaid
        )
    }

    private func openAIBody(
        _ model: AgentModel = .luna,
        tools: [AgentToolSchema] = [],
        messages: [AgentRequestMessage] = []
    ) -> [String: Any] {
        OpenAIRequestBody.build(
            model: model, system: "Instructions", tools: tools, messages: messages)
    }

    private func reasoning(
        _ summary: String, encrypted: String, id: String, model: AgentModel
    ) -> AgentRequestBlock {
        .content(.openAIReasoning(
            summary: summary, encryptedContent: encrypted, itemID: id, model: .builtIn(model)))
    }
}

@Suite("Agent provider persistence")
@MainActor
struct AgentProviderPersistenceTests {
    @Test func reasoningDefaultsToMediumForEveryModel() throws {
        try withDefaults { defaults in
            for model in AgentModel.allCases {
                #expect(AgentReasoningPreferences.effort(for: model, defaults: defaults) == .medium)
            }
        }
    }

    @Test func reasoningSelectionsPersistAndRestorePerModel() throws {
        try withDefaults { defaults in
            let service = AgentService(userDefaults: defaults)
            let selections: [(AgentModel, AgentReasoningEffort)] = [
                (.sol, .high), (.sonnet5, .max), (.terra, .minimal),
            ]
            for (model, effort) in selections {
                service.model = .builtIn(model)
                service.reasoningEffort = effort
            }
            for (model, effort) in selections {
                service.model = .builtIn(model)
                #expect(service.reasoningEffort == effort)
            }
            let restored = AgentService(userDefaults: defaults)
            #expect(restored.model == .builtIn(.terra))
            #expect(restored.reasoningEffort == .minimal)
            restored.model = .builtIn(.sol)
            #expect(restored.reasoningEffort == .high)
        }
    }

    @Test func baseURLSelectionsPersistPerProviderAndResetToDefault() throws {
        try withDefaults { defaults in
            #expect(AgentBaseURLPreferences.storedString(for: .anthropic, defaults: defaults).isEmpty)
            #expect(
                AgentBaseURLPreferences.chatEndpoint(for: .openAI, defaults: defaults).absoluteString
                    == "https://api.openai.com/v1/responses"
            )

            AgentBaseURLPreferences.set(
                "https://proxy.example/", for: .anthropic, defaults: defaults)
            AgentBaseURLPreferences.set(
                "https://openrouter.ai/api/v1", for: .openAI, defaults: defaults)
            #expect(
                AgentBaseURLPreferences.storedString(for: .anthropic, defaults: defaults)
                    == "https://proxy.example/"
            )
            #expect(
                AgentBaseURLPreferences.chatEndpoint(for: .anthropic, defaults: defaults)
                    .absoluteString == "https://proxy.example/v1/messages"
            )
            #expect(
                AgentBaseURLPreferences.chatEndpoint(for: .openAI, defaults: defaults)
                    .absoluteString == "https://openrouter.ai/api/v1/responses"
            )

            AgentBaseURLPreferences.set(
                "https://api.anthropic.com", for: .anthropic, defaults: defaults)
            AgentBaseURLPreferences.set(nil, for: .openAI, defaults: defaults)
            #expect(AgentBaseURLPreferences.storedString(for: .anthropic, defaults: defaults).isEmpty)
            #expect(AgentBaseURLPreferences.storedString(for: .openAI, defaults: defaults).isEmpty)
        }
    }

    @Test func customModelsPersistAndAppearInAvailableModels() throws {
        try withDefaults { defaults in
            let store = CustomAgentModelStore(defaults: defaults)
            let openAI = try store.add(
                provider: .openAI, modelID: "gpt-4.1", displayName: "GPT 4.1")
            let anthropic = try store.add(
                provider: .anthropic, modelID: "claude-sonnet-4-5", displayName: "")
            #expect(anthropic.displayName == "claude-sonnet-4-5")
            #expect(throws: CustomAgentModelError.duplicateModelID) {
                try store.add(provider: .openAI, modelID: "GPT-4.1", displayName: "Dup")
            }
            #expect(throws: CustomAgentModelError.duplicatesBuiltIn) {
                try store.add(provider: .openAI, modelID: "gpt-5.6-terra", displayName: "Terra")
            }

            let service = AgentService(userDefaults: defaults, customModels: store)
            #expect(service.availableModels.contains(.custom(openAI)))
            #expect(service.availableModels.contains(.custom(anthropic)))
            service.model = .custom(openAI)
            #expect(service.model.apiModelID == "gpt-4.1")
            #expect(
                AgentRouting.route(
                    model: service.model,
                    credentials: AgentCredentialSnapshot([.openAI: "key"]),
                    hasHostedCredits: true,
                    hasPaidPlan: true
                ) == .direct
            )
            #expect(
                AgentRouting.route(
                    model: service.model,
                    credentials: AgentCredentialSnapshot(),
                    hasHostedCredits: true,
                    hasPaidPlan: true
                ) == .unavailable
            )

            let restoredStore = CustomAgentModelStore(defaults: defaults)
            let restored = AgentService(userDefaults: defaults, customModels: restoredStore)
            #expect(restored.model == .custom(openAI))
            #expect(Set(restoredStore.models.map(\.modelID)) == ["claude-sonnet-4-5", "gpt-4.1"])

            restoredStore.remove(id: openAI.id)
            #expect(restored.model == .defaultModel)
        }
    }

    @Test func customModelRequestBodiesUseConfiguredAPIModelIDs() throws {
        let openAI = CustomAgentModel(
            provider: .openAI, modelID: "gpt-4.1-mini", displayName: "Mini")
        let anthropic = CustomAgentModel(
            provider: .anthropic, modelID: "claude-sonnet-4-5", displayName: "Sonnet")
        let openAIBody = OpenAIRequestBody.build(
            model: .custom(openAI), system: "Instructions", tools: [], messages: [])
        let anthropicBody = AnthropicRequestBody.build(
            model: .custom(anthropic), system: "Instructions", tools: [], messages: [])
        #expect(openAIBody["model"] as? String == "gpt-4.1-mini")
        #expect(anthropicBody["model"] as? String == "claude-sonnet-4-5")
    }

    @Test func runSettingsRemainStableAfterPickerChanges() throws {
        try withDefaults { defaults in
            let service = AgentService(userDefaults: defaults)
            service.model = .builtIn(.sol)
            service.reasoningEffort = .high
            let snapshot = service.snapshotRunSettings()
            service.reasoningEffort = .low
            service.model = .builtIn(.fable5)
            #expect(snapshot == AgentRunSettings(model: .sol, reasoningEffort: .high))
            #expect(service.snapshotRunSettings()
                == AgentRunSettings(model: .fable5, reasoningEffort: .medium))
        }
    }

    @Test func encryptedReasoningRoundTripsWithoutExposingOpaqueContent() throws {
        let block = AgentContentBlock.openAIReasoning(
            summary: "Inspected the timeline", encryptedContent: "opaque-encrypted-data",
            itemID: "rs_123", model: .builtIn(.sol)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(block)
        let decoded = try JSONDecoder().decode(AgentContentBlock.self, from: encoded)
        #expect(try encoder.encode(decoded) == encoded)
        let body = AnthropicRequestBody.build(
            model: .sonnet5, system: "", tools: [],
            messages: [AgentRequestMessage(role: .assistant, content: [.content(decoded)])]
        )
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("opaque-encrypted-data"))
    }

    @Test func legacyThinkingJSONStillDecodes() throws {
        let data = Data(#"{"kind":"thinking","text":"Legacy summary","signature":"signed"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentContentBlock.self, from: data)
        guard case .thinking(let text, let signature) = decoded else {
            Issue.record("Expected legacy thinking")
            return
        }
        #expect(text == "Legacy summary")
        #expect(signature == "signed")
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "AgentProviderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
