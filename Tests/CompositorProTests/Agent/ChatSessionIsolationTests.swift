import Foundation
import Observation
import Synchronization
import Testing
@testable import CompositorPro

@Suite("Chat session isolation")
@MainActor
struct ChatSessionIsolationTests {
    @Test func newChatPreservesThePreviousUnsentComposer() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            let mention = AgentMention(displayName: "Source", mediaRef: "source", type: .image)
            service.draft = "Unsent edit @Source "
            service.mentions = [mention]

            service.newChat()
            #expect(service.draft.isEmpty)
            #expect(service.mentions.isEmpty)
            #expect(service.sessions.contains { $0.id == original })

            service.draft = "Another draft"
            service.selectSession(original)
            #expect(service.draft == "Unsent edit @Source ")
            #expect(service.mentions.map(\.id) == [mention.id])
        }
    }

    @Test func selectingChatsPreservesTheirAttachmentsAndErrors() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.messages = [AgentMessage(role: .user, blocks: [.text("First request")])]
            service.draft = "@First "
            service.mentions = [AgentMention(displayName: "First", mediaRef: "first", type: .image)]
            service.streamError = .upstream("First chat error")
            service.newChat()
            let other = try #require(service.currentSessionId)
            service.draft = "@Second "
            service.mentions = [AgentMention(displayName: "Second", mediaRef: "second", type: .video)]

            service.selectSession(original)
            #expect(service.draft == "@First ")
            #expect(service.mentions.map(\.mediaRef) == ["first"])
            if case .upstream(let message) = service.streamError {
                #expect(message == "First chat error")
            } else {
                Issue.record("Selecting a tab discarded its error")
            }
            service.selectSession(other)
            #expect(service.draft == "@Second ")
            #expect(service.mentions.map(\.mediaRef) == ["second"])
            #expect(service.streamError == nil)
        }
    }

    @Test func creatingAChatKeepsThePreviousResponseRunning() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.messages = [AgentMessage(role: .user, blocks: [.text("First request")])]
            let client = ChatIsolationClient()
            let run = service.kickOffStream(conversationID: original, traceID: UUID(),
                                           settings: service.snapshotRunSettings(), client: client)
            await client.entered.wait()

            service.newChat()
            let selected = service.currentSessionId
            #expect(!service.isStreaming)
            await client.release.open()
            await run.value

            #expect(await !client.wasCancelled)
            #expect(service.currentSessionId == selected)
            #expect(service.messages.isEmpty)
            let stored = try #require(service.sessions.first { $0.id == original })
            #expect(stored.messages.contains { $0.role == .assistant && !$0.blocks.isEmpty })
        }
    }

    @Test func runStateChangesNotifyTheInterfaceWithoutMessageChanges() async throws {
        try await withService { service in
            let probe = ChatObservationProbe()
            withObservationTracking {
                _ = service.isStreaming
            } onChange: {
                probe.changed.withLock { $0 = true }
            }
            let run = service.kickOffStream(conversationID: try #require(service.currentSessionId),
                                           traceID: UUID(), settings: service.snapshotRunSettings(),
                                           client: ChatIsolationClient())
            #expect(probe.changed.withLock { $0 })
            service.cancel()
            await run.value
        }
    }

    @Test func delayedComposerUpdatesStayWithTheirOriginatingChat() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.newChat()
            let selected = try #require(service.currentSessionId)
            service.draft = "Visible draft"
            service.setDraft("Delayed original draft", in: original)
            service.setMentions([AgentMention(displayName: "Source", mediaRef: "source", type: .image)], in: original)

            #expect(service.draft == "Visible draft")
            #expect(service.mentions.isEmpty)
            service.selectSession(original)
            #expect(service.draft == "Delayed original draft")
            #expect(service.mentions.map(\.mediaRef) == ["source"])
            service.deleteSession(original)
            service.setDraft("Stale update", in: original)
            #expect(!service.submitDraft(in: original))
            #expect(service.currentSessionId == selected)
            #expect(service.draft == "Visible draft")
            #expect(!service.containsSession(original))
        }
    }

    @Test func delayedMediaAttachmentStaysWithItsOriginatingComposer() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.newChat()
            service.draft = "Visible draft"
            let asset = MediaAsset(id: "source", url: URL(fileURLWithPath: "/source.png"),
                                   type: .image, name: "Source", duration: 1)
            service.attachMention(for: asset, conversationID: original)

            #expect(service.draft == "Visible draft")
            #expect(service.mentions.isEmpty)
            service.selectSession(original)
            #expect(service.draft == "@Source ")
            #expect(service.mentions.map(\.mediaRef) == [asset.id])
        }
    }

    @Test func refusedSubmissionPreservesTheDraftAndAttachments() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.draft = "Edit @Source"
            service.mentions = [AgentMention(displayName: "Source", mediaRef: "source", type: .image)]

            #expect(!service.submitDraft(in: original))
            #expect(service.draft == "Edit @Source")
            #expect(service.mentions.map(\.mediaRef) == ["source"])
            #expect(service.messages.isEmpty)
            #expect(!service.isStreaming)
        }
    }

    @Test func closingTheOnlyTabPreservesItsRunAndDraft() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.messages = [AgentMessage(role: .user, blocks: [.text("First request")])]
            service.draft = "Next edit"
            let client = ChatIsolationClient()
            let run = service.kickOffStream(conversationID: original, traceID: UUID(),
                                           settings: service.snapshotRunSettings(), client: client)
            await client.entered.wait()
            service.closeTab(original)

            #expect(service.currentSessionId != original)
            #expect(service.isStreaming(in: original))
            #expect(!service.isStreaming)
            await client.release.open()
            await run.value
            service.selectSession(original)
            #expect(service.draft == "Next edit")
            #expect(service.messages.contains { $0.role == .assistant })
            #expect(await !client.wasCancelled)
        }
    }

    @Test(arguments: [false, true])
    func stoppingOrDeletingAChatPreservesTheOtherRun(delete: Bool) async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.messages = [AgentMessage(role: .user, blocks: [.text("First request")])]
            let firstClient = ChatIsolationClient()
            let firstRun = service.kickOffStream(conversationID: original, traceID: UUID(),
                                                settings: service.snapshotRunSettings(), client: firstClient)
            await firstClient.entered.wait()
            service.newChat()
            let other = try #require(service.currentSessionId)
            service.messages = [AgentMessage(role: .user, blocks: [.text("Second request")])]
            let secondClient = ChatIsolationClient()
            let secondRun = service.kickOffStream(conversationID: other, traceID: UUID(),
                                                 settings: service.snapshotRunSettings(), client: secondClient)
            await secondClient.entered.wait()

            if delete { service.deleteSession(other) }
            else { service.cancel() }
            await secondRun.value
            #expect(service.isStreaming(in: original))
            #expect(!service.isStreaming(in: other))
            #expect(await secondClient.wasCancelled)
            await firstClient.release.open()
            await firstRun.value
            #expect(await !firstClient.wasCancelled)
            let stored = try #require(service.sessions.first { $0.id == original })
            #expect(stored.messages.contains { $0.role == .assistant && !$0.blocks.isEmpty })
        }
    }

    @Test func backgroundCompletionDoesNotClearTheVisibleRun() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.messages = [AgentMessage(role: .user, blocks: [.text("First request")])]
            let firstClient = ChatIsolationClient()
            let firstRun = service.kickOffStream(conversationID: original, traceID: UUID(),
                                                settings: service.snapshotRunSettings(), client: firstClient)
            await firstClient.entered.wait()
            service.newChat()
            service.messages = [AgentMessage(role: .user, blocks: [.text("Second request")])]
            let secondClient = ChatIsolationClient()
            let secondRun = service.kickOffStream(conversationID: try #require(service.currentSessionId), traceID: UUID(),
                                                 settings: service.snapshotRunSettings(), client: secondClient)
            await secondClient.entered.wait()
            await firstClient.release.open()
            await firstRun.value

            #expect(service.isStreaming)
            #expect(service.requestProgress != nil)
            #expect(service.messages.count == 2)
            #expect(service.messages.last?.blocks.isEmpty == true)
            service.cancel()
            await secondRun.value
        }
    }

    @Test func stoppingDiscardsQueuedWorkWithoutRestartingTheChat() async throws {
        try await withService { service in
            let original = try #require(service.currentSessionId)
            service.messages = [AgentMessage(role: .user, blocks: [.text("First request")])]
            let client = ChatIsolationClient()
            let run = service.kickOffStream(conversationID: original, traceID: UUID(),
                                           settings: service.snapshotRunSettings(), client: client)
            await client.entered.wait()
            #expect(service.send(text: "Queued request", mentions: []))
            #expect(service.queuedMessageCount == 1)
            service.cancel()
            await run.value

            #expect(await client.requestCount == 1)
            #expect(service.queuedMessageCount == 0)
            #expect(!service.isStreaming)
            #expect(service.messages.count == 1)
        }
    }

    @Test func historyRestorePreservesDraftsCreatedWhileLoading() async throws {
        let entered = ChatIsolationGate()
        let release = ChatIsolationGate()
        let stored = ChatSession(messages: [AgentMessage(role: .user, blocks: [.text("Stored request")])])
        try await withService(sessionLoader: { _ in
            await entered.open()
            await release.wait()
            return [stored]
        }) { service in
            let original = try #require(service.currentSessionId)
            service.draft = "First live draft"
            let restore = service.loadSessions(from: nil)
            await entered.wait()
            service.newChat()
            let selected = service.currentSessionId
            service.draft = "Second live draft"
            service.editingProgress.completed = ["Live edit"]
            await release.open()
            await restore.value

            #expect(service.currentSessionId == selected)
            #expect(service.draft == "Second live draft")
            #expect(service.draft(in: original) == "First live draft")
            #expect(service.sessions.first { $0.id == stored.id }?.isOpen == false)
            #expect(service.editingProgress.completed == ["Live edit"])
        }
    }

    @Test func closeDrainWaitsForHistoryRestoreBeforeTheSaveSnapshot() async throws {
        let entered = ChatIsolationGate()
        let release = ChatIsolationGate()
        let stored = ChatSession(messages: [AgentMessage(role: .user, blocks: [.text("Stored request")])])
        try await withService(sessionLoader: { _ in
            await entered.open()
            await release.wait()
            return [stored]
        }) { service in
            let restore = service.loadSessions(from: nil)
            let drainEntered = PackageTestSignal()
            let finished = ChatObservationProbe()
            let drain = Task {
                drainEntered.signal()
                await service.cancelAndWait()
                finished.changed.withLock { $0 = true }
            }
            await drainEntered.wait()
            await entered.wait()
            #expect(!finished.changed.withLock { $0 })
            await release.open()
            await drain.value
            await restore.value

            #expect(finished.changed.withLock { $0 })
            #expect(service.sessions.first { $0.id == stored.id }?.messages.map(\.id) == stored.messages.map(\.id))
        }
    }

    @Test func submissionDuringCloseDrainPreservesItsComposer() async throws {
        let entered = ChatIsolationGate()
        let release = ChatIsolationGate()
        try await withService(sessionLoader: { _ in
            await entered.open()
            await release.wait()
            return []
        }) { service in
            let id = try #require(service.currentSessionId)
            let restore = service.loadSessions(from: nil)
            await entered.wait()
            let drainEntered = PackageTestSignal()
            let drain = Task {
                drainEntered.signal()
                await service.cancelAndWait()
            }
            await drainEntered.wait()
            service.draft = "Keep this draft @Source"
            service.mentions = [AgentMention(displayName: "Source", mediaRef: "source", type: .image)]

            #expect(!service.submitDraft(in: id))
            #expect(service.draft == "Keep this draft @Source")
            #expect(service.mentions.map(\.mediaRef) == ["source"])
            #expect(service.messages.isEmpty)
            if case .stopping? = service.streamError {} else { Issue.record("Expected stopping refusal") }
            await release.open()
            await drain.value
            await restore.value
        }
    }

    private func withService(sessionLoader: @escaping @Sendable (URL?) async -> [ChatSession] = ChatSessionStore.load,
                             _ operation: @MainActor (AgentService) async throws -> Void) async throws {
        let suite = "chat-isolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try await MediaInputIdentityFixtures.makeFiles()
        let service = AgentService(userDefaults: defaults,
                                   skillStore: SkillStore(directory: directory.appendingPathComponent("skills")),
                                   credentialLoader: { AgentCredentialSnapshot() }, customKeyLoader: { _ in "" },
                                   sessionLoader: sessionLoader)
        do {
            try await operation(service)
        } catch {
            await service.cancelAndWait()
            try await MediaInputIdentityFixtures.remove(directory)
            throw error
        }
        await service.cancelAndWait()
        try await MediaInputIdentityFixtures.remove(directory)
    }
}

private final class ChatObservationProbe: Sendable {
    let changed = Mutex(false)
}

private actor ChatIsolationClient: AgentClient {
    let entered = ChatIsolationGate()
    let release = ChatIsolationGate()
    private(set) var wasCancelled = false
    private(set) var requestCount = 0

    nonisolated func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                            context: AgentRequestContext) -> AgentStreamOperation {
        makeAgentStream { continuation in
            await self.respond(continuation, context: context)
        }
    }

    private func respond(_ continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
                         context: AgentRequestContext) async {
        requestCount += 1
        await withTaskCancellationHandler {
            await entered.open()
            await release.wait()
        } onCancel: {
            Task { await self.cancelResponse() }
        }
        guard !Task.isCancelled else { return }
        continuation.yield(.textDelta("Reply for \(context.conversationID.uuidString)"))
        continuation.yield(.messageStop(stopReason: .endTurn))
    }

    private func cancelResponse() async {
        wasCancelled = true
        await release.open()
    }
}

private actor ChatIsolationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
