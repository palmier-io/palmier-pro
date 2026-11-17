import Foundation
import Testing
@testable import CompositorPro

@Suite("Local agent harnesses")
struct LocalAgentHarnessTests {
    @Test(arguments: LocalAgentHarness.allCases)
    func requestsKeepPromptsOffArgumentsAndScopeToolsToThisChat(_ harness: LocalAgentHarness) async throws {
        let prompt = "Inspect the timeline. Keep `literal` and $(literal) unchanged."
        let endpoint = URL(string: "http://127.0.0.1:54321/mcp")!
        let request = try await LocalAgentRequest.prepare(
            harness: harness, effort: .high, system: "Compositor test instructions",
            messages: [.init(role: .user, content: [.content(.text(prompt))])], endpoint: endpoint,
            modelID: "provider-model"
        )
        do {
            #expect(!request.arguments.contains(where: { $0.contains(prompt) }))
            #expect(String(decoding: request.input, as: UTF8.self).contains(prompt))
            #expect(Array(request.arguments.prefix(2)) == ["--model", "provider-model"])
            #expect(!request.arguments.contains(where: { $0.contains("dangerously") || $0.contains("bypassPermissions") }))
            let config = try await configuration(at: request.directory.appendingPathComponent(".agents/mcp_config.json"))
            #expect(config == endpoint.absoluteString)
            try await request.cleanup()
            #expect(await !exists(request.directory))
        } catch {
            try await request.cleanup()
            throw error
        }
    }

    @Test @MainActor
    func selectingAnInstalledAgentUsesItsAccountAndPreservesAPIPreferences() async throws {
        let name = "LocalAgentHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AgentService(userDefaults: defaults, credentialLoader: { .init() }, customKeyLoader: { _ in "" },
                                   sessionLoader: { _ in [] }, localAgentDiscovery: { [.antigravity: URL(fileURLWithPath: "/fixture/agy")] })
        await service.reloadLocalAgents().value
        let originalModel = service.model
        service.selectLocalHarness(.antigravity)
        #expect(service.canStream)
        #expect(service.activeBYOKProvider == nil)
        #expect(service.model == originalModel)
        #expect(service.setLocalModelID("gemini-example", for: .antigravity))
        service.reasoningEffort = .high
        let captured = service.snapshotRunSettings()
        #expect(captured.localHarness == .antigravity)
        #expect(captured.localModelID == "gemini-example")
        #expect(captured.reasoningEffort == .high)
        #expect(service.selectedAgentTitle == "Antigravity · gemini-example")

        service.selectAPIModel(.terra)
        #expect(service.selectedLocalHarness == nil)
        #expect(service.snapshotRunSettings().localHarness == nil)
        #expect(!service.canStream)
        #expect(captured.localHarness == .antigravity)
        await service.cancelAndWait()
    }

    @Test @MainActor
    func missingInstallationPreservesTheDraftAndInvalidModelsPreserveSelection() async throws {
        let name = "LocalAgentHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AgentService(userDefaults: defaults, credentialLoader: { .init() }, customKeyLoader: { _ in "" },
                                   sessionLoader: { _ in [] }, localAgentDiscovery: { [:] })
        await service.reloadLocalAgents().value
        service.selectLocalHarness(.antigravity)
        service.draft = "Inspect my project"
        #expect(!service.submitDraft(in: try #require(service.currentSessionId)))
        #expect(service.draft == "Inspect my project")
        #expect(service.messages.isEmpty)
        if case .localAgent(.notInstalled(.antigravity)) = service.streamError {} else { Issue.record("Missing CLI was not reported") }
        #expect(service.setLocalModelID("valid-model", for: .antigravity))
        #expect(!service.setLocalModelID("bad\nmodel", for: .antigravity))
        #expect(!service.setLocalModelID("--dangerously-skip-permissions", for: .antigravity))
        #expect(!service.setLocalModelID(String(repeating: "x", count: 257), for: .antigravity))
        #expect(service.localModelID(for: .antigravity) == "valid-model")
        await service.cancelAndWait()
    }

    @concurrent private func configuration(at url: URL) async throws -> String? {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let servers = json?["mcpServers"] as? [String: [String: String]]
        return servers?["compositor-pro"]?["serverUrl"]
    }

    @concurrent private func exists(_ url: URL) async -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Suite("Local agent response decoding")
struct LocalAgentStreamDecoderTests {
    @Test(arguments: LocalAgentHarness.allCases)
    func toolActivityNeverBecomesASecondEditAndFinalTextIsNotDuplicated(_ harness: LocalAgentHarness) async throws {
        let lines: [String]
        switch harness {
        case .antigravity:
            lines = [
                #"{"event":"init"}"#,
                #"{"event":"step_update","step_update":{"step_type":"mcp_tool_call"}}"#,
                #"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Hello "}}"#,
                #"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"world"}}"#,
                #"{"event":"result","result":{"status":"SUCCESS","response":"Hello world"}}"#
            ]
        case .claudeCode:
            lines = [
                #"{"type":"stream_event","event":{"type":"message_start"}}"#,
                #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"move_clips"}}}"#,
                #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}"#,
                #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello world"}]}}"#,
                #"{"type":"result","subtype":"success","result":"Hello world","is_error":false}"#
            ]
        case .codex:
            lines = [
                #"{"type":"thread.started"}"#,
                #"{"type":"item.started","item":{"id":"tool","type":"mcp_tool_call","tool":"move_clips"}}"#,
                #"{"type":"item.updated","item":{"id":"answer","type":"agent_message","text":"Hello "}}"#,
                #"{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"Hello world"}}"#,
                #"{"type":"turn.completed"}"#
            ]
        }
        let decoder = LocalAgentStreamDecoder(harness: harness)
        var events: [AgentStreamEvent] = []
        for line in lines { events += try await decoder.receive(Data(line.utf8)) }
        try await decoder.finish(status: 0, diagnostics: "")
        #expect(events.compactMap { if case .textDelta(let text) = $0 { return text }; return nil }.joined() == "Hello world")
        #expect(events.contains { if case .activity(.preparingTool) = $0 { return true }; return false })
        #expect(!events.contains { if case .toolUseComplete = $0 { return true }; return false })
    }

    @Test func missingTerminalEventAndSoftDenialsCannotReportSuccess() async throws {
        let incomplete = LocalAgentStreamDecoder(harness: .codex)
        _ = try await incomplete.receive(Data(#"{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"Done"}}"#.utf8))
        await #expect(throws: LocalAgentFailure.incompleteOutput) { try await incomplete.finish(status: 0, diagnostics: "") }
        let denied = LocalAgentStreamDecoder(harness: .antigravity)
        _ = try await denied.receive(Data(#"{"event":"result","result":{"status":"SUCCESS","response":"Done"}}"#.utf8))
        await #expect(throws: LocalAgentFailure.permissionRequired(.antigravity)) {
            try await denied.finish(status: 0, diagnostics: "MCP tool requires approval and was soft-denied")
        }
    }

    @Test func malformedOutputAndProviderErrorsDoNotExposePrompts() async throws {
        let decoder = LocalAgentStreamDecoder(harness: .antigravity)
        await #expect(throws: LocalAgentFailure.invalidOutput) { _ = try await decoder.receive(Data("not-json".utf8)) }
        do {
            _ = try await decoder.receive(Data(#"{"event":"result","result":{"status":"ERROR","error":"private-prompt credential-example"}}"#.utf8))
            Issue.record("Failed agent result was accepted")
        } catch {
            #expect(error as? LocalAgentFailure == .runFailed(.antigravity, 1))
            #expect(!error.localizedDescription.contains("private-prompt"))
            #expect(!error.localizedDescription.contains("credential-example"))
        }
    }
}
