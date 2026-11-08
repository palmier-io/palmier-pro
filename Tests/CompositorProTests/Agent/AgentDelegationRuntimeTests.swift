import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Agent delegation runtime")
@MainActor
struct AgentDelegationRuntimeTests {
    @Test func parentAppliesDraftsThroughSharedToolsAndMCPUndo() async throws {
        try await withRuntime { service, harness, client in
            let probe = DelegationRuntimeClient()
            let run = service.kickOffStream(conversationID: try #require(service.currentSessionId), traceID: UUID(),
                                           settings: service.snapshotRunSettings(), client: probe)
            await run.value
            #expect(await probe.childRequests == 2)
            #expect(await probe.childToolsWereEmpty)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).count == 1)
            let read = try await client.callTool(name: "get_timeline")
            #expect(read.isError != true)
            let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first)
            #expect(clip.mediaRef == "source")
            #expect(clip.durationFrames == 60)
            let undone = try await client.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(!service.isStreaming)
            let (tools, _) = try await client.listTools()
            #expect(!tools.contains { $0.name == AgentDelegationTool.name })
        }
    }

    @Test func unsupportedChildModelReturnsToNormalParentToolsWithoutRespawning() async throws {
        try await withRuntime { service, harness, _ in
            let probe = DelegationRuntimeClient(childFailure: .httpError(provider: .custom, status: 404, body: "model_not_found"))
            let run = service.kickOffStream(conversationID: try #require(service.currentSessionId), traceID: UUID(),
                settings: service.snapshotRunSettings(), client: probe)
            await run.value
            #expect(await probe.childRequests == 2)
            #expect(await probe.fallbackWasAdvertised)
            #expect(await probe.delegationToolRemovedAfterFailure)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).count == 1)
        }
    }

    @Test func authorizationFailureDoesNotAdvertiseNormalFallback() async throws {
        try await withRuntime { service, harness, _ in
            let probe = DelegationRuntimeClient(childFailure: .httpError(provider: .custom, status: 401, body: "invalid_api_key"),
                finishAfterDelegation: true)
            let run = service.kickOffStream(conversationID: try #require(service.currentSessionId), traceID: UUID(),
                settings: service.snapshotRunSettings(), client: probe)
            await run.value
            #expect(await probe.blockedWasAdvertised)
            #expect(await probe.fallbackWasAdvertised == false)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(service.messages.contains { $0.blocks.contains {
                if case .toolResult(let id, let content, let isError) = $0 {
                    return id == "delegate" && isError && content.contains {
                        if case .text(let text) = $0 { return text.contains("authentication_required") && text.contains("refused") }; return false
                    }
                }
                return false
            } })
        }
    }

    @Test(arguments: ["{}", "{\"tasks\":[]}", "{\"tasks\":[{}]}",
        "{\"tasks\":[{\"id\":1,\"objective\":\"Draft\",\"context\":\"Evidence\"}]}",
        "{\"tasks\":[{\"id\":\"task\",\"objective\":\"Draft\",\"context\":\"Evidence\",\"edit\":true}]}" ])
    func runtimeSchemaRejectsMissingUnknownAndWrongTypedArguments(input: String) {
        #expect(throws: (any Error).self) { _ = try AgentDelegationTool.tasks(from: input) }
    }

    @Test(arguments: ["timeline", "storyboard", "model", "editor"])
    func changedContextRefusesChildDrafts(change: String) async throws {
        try await withRuntime { service, harness, _ in
            let probe = DelegationRuntimeClient(holdChildren: true)
            let context = AgentRequestContext(conversationID: try #require(service.currentSessionId), traceID: UUID(),
                spanID: UUID(), inputMessageID: UUID(), outputMessageID: UUID(), projectID: nil)
            let task = Task {
                await service.executeDelegation(input: DelegationRuntimeClient.input, client: probe,
                    delegation: AgentDelegation(), context: context, settings: service.snapshotRunSettings())
            }
            await probe.waitForChildren()
            switch change {
            case "timeline": harness.editor.timeline.width = 1280
            case "storyboard": harness.editor.editPlans = [EditPlan(id: "changed", name: "Changed",
                timelineId: harness.editor.activeTimelineId, fps: 30, width: 1920, height: 1080)]
            case "model": service.model = .opus5
            default: service.editor = ToolHarness().editor
            }
            await probe.releaseChildren()
            let result = await task.value
            #expect(result.isError)
            #expect(result.content.contains { if case .text(let text) = $0 { return text.contains("delegation_stale") }; return false })
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        }
    }

    @Test func parentCannotUseChildDraftsToBypassProductionApproval() async throws {
        try await withRuntime { service, harness, client in
            let create = try await client.callTool(name: "plan_edit", arguments: ["action": .string("create"), "plan": .object([
                "planId": .string("board"), "name": .string("Managed board"),
                "shots": .array([.object(["shotId": .string("scene"), "title": .string("Scene"),
                    "startFrame": .int(0), "endFrame": .int(60), "mediaRef": .string("source")])]),
            ])])
            #expect(create.isError != true)
            _ = try await client.callTool(name: "plan_edit", arguments: ["action": .string("prepare_storyboard"), "planId": .string("board")])
            var plan = try #require(harness.editor.editPlan(id: "board"))
            #expect(plan.productionRun?.phase == .awaitingStoryboardApproval)
            plan.status = .approved
            harness.editor.editPlans = [plan]
            let baseline = harness.editor.editPlans
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let probe = DelegationRuntimeClient(editName: "apply_plan", editInput: "{\"planId\":\"board\",\"commit\":true}")
            let run = service.kickOffStream(conversationID: try #require(service.currentSessionId), traceID: UUID(),
                settings: service.snapshotRunSettings(), client: probe)
            await run.value
            #expect(await probe.childRequests == 2)
            #expect(harness.editor.editPlans == baseline)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
            #expect(!undo.canUndo)
            #expect(service.messages.contains { $0.blocks.contains {
                if case .toolResult(let id, let content, let isError) = $0 {
                    return id == "edit" && isError && content.contains {
                        if case .text(let text) = $0 { return text.contains("Explicit approval") }; return false
                    }
                }
                return false
            } })
        }
    }

    @Test func sessionSwitchCancelsChildrenWithoutClearingNewRun() async throws {
        try await withRuntime { service, harness, _ in
            let probe = DelegationRuntimeClient(holdChildren: true)
            let original = try #require(service.currentSessionId)
            let oldRun = service.kickOffStream(conversationID: original, traceID: UUID(),
                settings: service.snapshotRunSettings(), client: probe)
            await probe.waitForChildren()
            service.newChat()
            service.messages = [AgentMessage(role: .user, blocks: [.text("New work")])]
            let newClient = DelegationRuntimeClient(holdParent: true)
            let newRun = service.kickOffStream(conversationID: try #require(service.currentSessionId), traceID: UUID(),
                settings: service.snapshotRunSettings(), client: newClient)
            await newClient.waitForParent()
            await oldRun.value
            #expect(service.isStreaming)
            #expect(service.messages.count == 2)
            #expect(service.messages.allSatisfy { $0.blocks.allSatisfy { if case .toolResult = $0 { return false }; return true } })
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
            service.cancel()
            await newRun.value
            #expect(!service.isStreaming)
        }
    }

    @Test func closeDrainWaitsForCanceledRunsAndPersistsTerminalReceipts() async throws {
        try await withRuntime { service, harness, _ in
            let probe = DelegationRuntimeClient(holdChildren: true)
            let original = try #require(service.currentSessionId)
            let run = service.kickOffStream(conversationID: original, traceID: UUID(),
                settings: service.snapshotRunSettings(), client: probe)
            await probe.waitForChildren()
            service.cancel()
            await service.cancelAndWait()
            await run.value
            #expect(!service.isStreaming)
            let session = try #require(service.sessions.first { $0.id == original })
            #expect(session.messages.contains { $0.blocks.contains {
                if case .toolResult(let id, _, let error) = $0 { return id == "delegate" && error }
                return false
            } })
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        }
    }

    @Test func cancellationWithoutClosePersistsItsFinalConversation() async throws {
        try await withRuntime { service, _, _ in
            let probe = DelegationRuntimeClient(holdChildren: true)
            let original = try #require(service.currentSessionId)
            let run = service.kickOffStream(conversationID: original, traceID: UUID(),
                settings: service.snapshotRunSettings(), client: probe)
            await probe.waitForChildren()
            service.cancel()
            await run.value
            let session = try #require(service.sessions.first { $0.id == original })
            #expect(session.messages.map(\.id) == service.messages.map(\.id))
            #expect(session.messages.contains { $0.blocks.contains {
                if case .toolResult(let id, _, let isError) = $0 { return id == "delegate" && isError }
                return false
            } })
        }
    }

    @Test func lateToolReceiptBelongsOnlyToOriginatingConversation() throws {
        let suite = "delegation-receipt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AgentService(userDefaults: defaults)
        let original = ChatSession()
        let selected = ChatSession()
        service.sessions = [original, selected]
        service.currentSessionId = selected.id
        service.appendToolResults([.toolResult(toolUseId: "old", content: [.text("canceled")], isError: true)], conversationID: original.id)
        #expect(service.messages.isEmpty)
        #expect(service.sessions.first { $0.id == original.id }?.messages.count == 1)
    }

    private func withRuntime(_ operation: @MainActor (AgentService, ToolHarness, Client) async throws -> Void) async throws {
        let suite = "delegation-runtime-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let harness = ToolHarness()
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        let asset = harness.addAsset(id: "source", type: .image)
        asset.url = directory.appendingPathComponent("original.png")
        try await asset.prepareInputIdentity()
        harness.editor.mediaManifest.entries.append(asset.toManifestEntry(projectURL: nil))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let service = AgentService(userDefaults: defaults, skillStore: SkillStore(directory: directory.appendingPathComponent("skills")))
        service.editor = harness.editor
        let session = ChatSession(messages: [AgentMessage(role: .user, blocks: [.text("Prepare two independent scene drafts")])])
        service.sessions = [session]
        service.currentSessionId = session.id
        service.messages = session.messages
        let server = Server(name: "delegation-tests", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: harness.editor))
        let transport = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "delegation-tests", version: "1")
        do {
            try await server.start(transport: transport.server)
            _ = try await client.connect(transport: transport.client)
            try await operation(service, harness, client)
        } catch {
            service.cancel()
            await server.stop()
            await client.disconnect()
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        service.cancel()
        await server.stop()
        await client.disconnect()
        try await MediaInputIdentityFixtures.remove(directory)
    }
}

private actor DelegationRuntimeClient: AgentClient {
    static let input = """
    {"tasks":[{"id":"first","objective":"Draft first scene","context":"Supplied first claim"},{"id":"second","objective":"Draft second scene","context":"Supplied second claim"}]}
    """
    private let holdChildren: Bool
    private let holdParent: Bool
    private let editName: String
    private let editInput: String
    private let childFailure: AgentClientTransportError?
    private let finishAfterDelegation: Bool
    private let childEntered = AsyncSemaphore(value: 0)
    private let childRelease = AsyncSemaphore(value: 0)
    private let parentEntered = AsyncSemaphore(value: 0)
    private let parentRelease = AsyncSemaphore(value: 0)
    private var parentRequests = 0
    private(set) var childRequests = 0
    private(set) var childToolsWereEmpty = true
    private(set) var fallbackWasAdvertised = false
    private(set) var blockedWasAdvertised = false
    private(set) var delegationToolRemovedAfterFailure = false

    init(holdChildren: Bool = false, holdParent: Bool = false, editName: String = "add_clips",
         editInput: String = "{\"entries\":[{\"mediaRef\":\"source\",\"startFrame\":0,\"endFrame\":60}]}",
         childFailure: AgentClientTransportError? = nil, finishAfterDelegation: Bool = false) {
        self.holdChildren = holdChildren
        self.holdParent = holdParent
        self.editName = editName
        self.editInput = editInput
        self.childFailure = childFailure
        self.finishAfterDelegation = finishAfterDelegation
    }

    nonisolated func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                            context: AgentRequestContext) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeAgentStream { continuation in
            let events = try await self.events(system: system, tools: tools)
            for event in events { continuation.yield(event) }
        }
    }

    private func events(system: String, tools: [AgentToolSchema]) async throws -> [AgentStreamEvent] {
        if tools.isEmpty {
            childRequests += 1
            childToolsWereEmpty = childToolsWereEmpty && tools.isEmpty
            await childEntered.signal()
            if holdChildren { try await childRelease.wait() }
            try Task.checkCancellation()
            if let childFailure { throw childFailure }
            return [.textDelta("Prepared draft from supplied evidence."), .messageStop(stopReason: .endTurn)]
        }
        parentRequests += 1
        if parentRequests > 1 {
            fallbackWasAdvertised = system.contains(AgentDelegationTool.fallbackInstructions)
            blockedWasAdvertised = system.contains(AgentDelegationTool.blockedInstructions)
            delegationToolRemovedAfterFailure = !tools.contains { $0.name == AgentDelegationTool.name }
        }
        await parentEntered.signal()
        if holdParent { try await parentRelease.wait() }
        try Task.checkCancellation()
        switch parentRequests {
        case 1: return [.toolUseComplete(id: "delegate", name: AgentDelegationTool.name, inputJSON: Self.input), .messageStop(stopReason: .toolUse)]
        case 2:
            if finishAfterDelegation { return [.textDelta("Preparation blocked."), .messageStop(stopReason: .endTurn)] }
            return [.toolUseComplete(id: "edit", name: editName, inputJSON: editInput), .messageStop(stopReason: .toolUse)]
        default: return [.textDelta("Drafts applied."), .messageStop(stopReason: .endTurn)]
        }
    }

    func waitForChildren() async {
        try? await childEntered.wait()
        try? await childEntered.wait()
    }
    func releaseChildren() async {
        await childRelease.signal()
        await childRelease.signal()
    }
    func waitForParent() async { try? await parentEntered.wait() }
}
