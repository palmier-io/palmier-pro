import AppKit
import Testing
@testable import CompositorPro

@Suite("App termination persistence", .serialized)
@MainActor
struct AppTerminationTests {
    @Test(.timeLimit(.minutes(1)))
    func quitCancelsAnAgentAfterAnEditAndPersistsBeforeReplyingOnce() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "ABCD1234-0000-0000-0000-000000000000", start: 0, duration: 30)
            ])])
            let undo = UndoManager()
            editor.undo.attach(undo)
            try await savePackageTestDocument(document)
            let service = editor.agentService
            service.messages = [.init(role: .user, blocks: [.text("Move the first clip to frame 60")])]
            let client = QuitEditingAgentClient()
            let conversation = try #require(service.currentSessionId)
            let run = service.kickOffStream(conversationID: conversation, traceID: UUID(),
                                           settings: service.snapshotRunSettings(), client: client)
            await client.waiting.wait()
            #expect(editor.timeline.tracks[0].clips[0].startFrame == 60)
            #expect(undo.canUndo)

            let delegate = AppDelegate()
            let finished = PackageTestSignal()
            var replies: [Bool] = []
            var servicesPrepared = false
            delegate.startTermination(projects: [document], prepareServices: { _ in servicesPrepared = true },
                didClose: {}, onError: { Issue.record("Unexpected quit failure: \($0)") }, sendReply: {
                    replies.append($0)
                    finished.signal()
                })
            await client.cancelled.wait()
            #expect(editor.projectPackageCoordinator.isClosing)
            #expect(replies.isEmpty && !servicesPrepared)
            delegate.startTermination(projects: [document], prepareServices: { _ in
                Issue.record("Repeated quit restarted shutdown")
            }, didClose: {}, onError: { _ in }, sendReply: { _ in Issue.record("Repeated quit replied") })
            await client.cleanupAllowed.open()
            await run.value
            await finished.wait()

            #expect(replies == [true] && servicesPrepared)
            #expect(editor.projectPackageCoordinator.isClosed)
            #expect(!service.isStreaming(in: conversation))
            let persisted = try await fixture.readPackage()
            #expect(persisted.projectFile.timelines.first?.tracks.first?.clips.first?.startFrame == 60)
            #expect(persisted.projectFile.timelines.first?.tracks.first?.clips.count == 1)
        }
    }

    @Test func homeWindowQuitWaitsForServicesAndRepliesOnce() async {
        let delegate = AppDelegate()
        let entered = PackageTestSignal()
        let release = PackageTestSignal()
        let finished = PackageTestSignal()
        var replies: [Bool] = []
        var closed = false
        delegate.startTermination(projects: [], prepareServices: { validate in
            entered.signal()
            await release.wait()
            try validate()
        }, didClose: { closed = true }, onError: { Issue.record("Unexpected quit failure: \($0)") }, sendReply: {
            replies.append($0)
            finished.signal()
        })
        await entered.wait()
        #expect(delegate.isTerminating && replies.isEmpty && !closed)
        delegate.startTermination(projects: [], prepareServices: { _ in
            Issue.record("Duplicate quit restarted service shutdown")
        }, didClose: {}, onError: { _ in }, sendReply: { _ in
            Issue.record("Duplicate quit replied")
        })
        release.signal()
        await finished.wait()
        #expect(replies == [true] && closed)
    }

    @Test func waitsForAdmittedWorkThenSavesBeforeReplyingOnce() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            try await savePackageTestDocument(document)
            let coordinator = document.editorViewModel.projectPackageCoordinator
            let entered = PackageTestSignal()
            let release = PackageTestSignal()
            let finished = PackageTestSignal()
            let pending = Task { @MainActor in
                try await coordinator.withIntent { _ in
                    entered.signal()
                    await release.wait()
                    document.editorViewModel.timeline.name = "Latest admitted edit"
                }
            }
            await entered.wait()
            let delegate = AppDelegate()
            var replies: [Bool] = []
            var servicesPrepared = false
            var closed = false
            delegate.startTermination(projects: [document], prepareServices: { _ in
                servicesPrepared = true
            }, didClose: { closed = true }, onError: { Issue.record("Unexpected quit failure: \($0)") }, sendReply: {
                replies.append($0)
                finished.signal()
            })
            #expect(coordinator.isClosing)
            #expect(replies.isEmpty)
            #expect(!servicesPrepared)
            #expect(!closed)
            #expect(throws: CancellationError.self) { try coordinator.admitIntent() }
            delegate.startTermination(projects: [document], prepareServices: { _ in }, didClose: {}, onError: { _ in }, sendReply: { _ in
                Issue.record("Duplicate termination request replied")
            })
            release.signal()
            try await pending.value
            await finished.wait()
            #expect(replies == [true])
            #expect(servicesPrepared && closed && coordinator.isClosed)
            let persisted = try await fixture.readPackage()
            #expect(persisted.projectFile.timelines.first?.name == "Latest admitted edit")
        }
    }

    @Test func failedFinalSaveRefusesQuitAndAllowsRetry() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            try await savePackageTestDocument(document)
            let original = try await fixture.readPackage()
            document.editorViewModel.mediaManifest.entries = [
                .init(id: "invalid", name: "Invalid", type: .video, source: .external(absolutePath: "/tmp/invalid"), duration: .nan),
            ]
            let delegate = AppDelegate()
            let failed = PackageTestSignal()
            var replies: [Bool] = []
            var errors = 0
            delegate.startTermination(projects: [document], prepareServices: { _ in Issue.record("Services stopped after save failure") },
                didClose: { Issue.record("Closed after save failure") }, onError: { _ in errors += 1 }, sendReply: {
                    replies.append($0)
                    failed.signal()
                })
            await failed.wait()
            #expect(replies == [false] && errors == 1)
            #expect(!delegate.isTerminating)
            #expect(!document.editorViewModel.projectPackageCoordinator.isClosing)
            let retained = try await fixture.readPackage()
            #expect(retained.projectFile.timelines == original.projectFile.timelines)
            #expect(retained.manifest == original.manifest)
            document.editorViewModel.mediaManifest.entries = []
            let retried = PackageTestSignal()
            delegate.startTermination(projects: [document], prepareServices: { _ in }, didClose: {}, onError: { Issue.record("Retry failed: \($0)") }, sendReply: {
                replies.append($0)
                retried.signal()
            })
            await retried.wait()
            #expect(replies == [false, true])
        }
    }
}

private actor QuitEditingAgentClient: AgentClient {
    let waiting = LocalAgentTestSignal()
    let cancelled = LocalAgentTestSignal()
    let cleanupAllowed = LocalAgentTestSignal()
    private var requestedEdit = false

    nonisolated func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                            context: AgentRequestContext) -> AgentStreamOperation {
        makeAgentStream { continuation in try await self.respond(continuation) }
    }

    private func respond(_ continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation) async throws {
        if !requestedEdit {
            requestedEdit = true
            continuation.yield(.toolUseComplete(id: "quit-test-move", name: "move_clips", inputJSON:
                #"{"moves":[{"clipId":"ABCD1234-0000-0000-0000-000000000000","toFrame":60}]}"#))
            continuation.yield(.messageStop(stopReason: .toolUse))
            return
        }
        try await withTaskCancellationHandler {
            await waiting.open()
            await cancelled.wait()
            await cleanupAllowed.wait()
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelled.open() }
        }
    }
}
