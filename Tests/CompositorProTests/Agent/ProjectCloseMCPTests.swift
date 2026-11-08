import AppKit
import Foundation
import MCP
import Testing
@testable import CompositorPro

@MainActor
private final class FencedCloseDocument: VideoProject {
    let fenceEntered = PackageTestSignal()
    let queuedSaveCompleted = PackageTestSignal()
    let closeCompleted = PackageTestSignal()
    private var fence: ProjectPackageCoordinator.SaveLease?
    private(set) var queuedSaveError: Error?
    private var shouldFence = true

    override func closeAfterSaving() async throws {
        defer { closeCompleted.signal() }
        try await super.closeAfterSaving()
    }

    override func saveBeforeClosing(using lease: ProjectPackageCoordinator.CloseLease) async throws {
        try await super.saveBeforeClosing(using: lease)
        guard shouldFence else { return }
        shouldFence = false
        editorViewModel.projectPackageCoordinator.enqueueSave { lease in
            self.fence = lease
            self.fenceEntered.signal()
        }
        save(to: try #require(fileURL), ofType: Self.typeIdentifier, for: .saveOperation) { error in
            self.queuedSaveError = error
            self.queuedSaveCompleted.signal()
        }
    }

    func releaseFence() {
        guard let fence else { return }
        self.fence = nil
        editorViewModel.projectPackageCoordinator.finishSave(fence) {}
    }
}

@Suite("Project closure through MCP", .serialized)
@MainActor
struct ProjectCloseMCPTests {
    @Test func closeDrainsLateSaveAndPersistsOnlyInjectedRegistry() async throws {
        try await withPackageTestFixture { fixture in
            let document = FencedCloseDocument(registry: fixture.registry)
            configure(document, fixture: fixture)
            defer { document.releaseFence() }
            document.editorViewModel.timeline.name = "Close proof"
            try await savePackageTestDocument(document)
            #expect(fixture.registry.entries.isEmpty)
            try await withClient(document: document, registry: fixture.registry) { client, executor in
                let (tools, _) = try await client.listTools()
                #expect(tools.contains { $0.name == "manage_project" })
                let closing = Task {
                    try await client.callTool(name: "manage_project", arguments: ["action": .string("close")])
                }
                await document.fenceEntered.wait()
                #expect(!document.editorViewModel.projectPackageCoordinator.isClosed)
                #expect(executor.sessionProject === document)
                #expect(AppState.shared.openProjects.contains(where: { $0 === document }))
                document.releaseFence()
                let result = try await closing.value
                try #require(result.isError != true)
                #expect(try payload(result)["status"] as? String == "closed")
                #expect(document.editorViewModel.projectPackageCoordinator.isClosed)
                #expect(!AppState.shared.openProjects.contains(where: { $0 === document }))
                #expect(executor.sessionProject == nil)
                await document.queuedSaveCompleted.wait()
                #expect(document.queuedSaveError == nil)
                #expect(try await fixture.readPackage().projectFile.timelines.first?.name == "Close proof")
                let entries = try await fixture.io.perform {
                    try JSONDecoder().decode([ProjectEntry].self,
                        from: Data(contentsOf: fixture.root.appendingPathComponent("registry.json")))
                }
                #expect(entries.count == 1)
                #expect(entries.first?.url == fixture.package)
                #expect(entries.first?.id == fixture.registry.id(for: fixture.package))
                let unbound = try await client.callTool(name: "get_timeline")
                #expect(unbound.isError == true)
                let registryBytes = try await fixture.contents(of: fixture.root.appendingPathComponent("registry.json"))
                try await document.closeAfterSaving()
                #expect(try await fixture.contents(of: fixture.root.appendingPathComponent("registry.json")) == registryBytes)
            }
        }
    }

    @Test func failedCloseRetainsBindingDocumentUndoAndLastSavedPackage() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let undo = UndoManager()
            document.editorViewModel.undo.attach(undo)
            try await savePackageTestDocument(document)
            let saved = try await fixture.readPackage()
            document.editorViewModel.mediaManifest.entries = [
                .init(id: "invalid", name: "Invalid", type: .video,
                    source: .project(relativePath: "media/invalid.mp4"), duration: .nan),
            ]
            try await withClient(document: document, registry: fixture.registry) { client, executor in
                let result = try await client.callTool(name: "manage_project", arguments: ["action": .string("close")])
                #expect(result.isError == true)
                let coordinator = document.editorViewModel.projectPackageCoordinator
                #expect(!coordinator.isClosing)
                #expect(!coordinator.isClosed)
                #expect(executor.sessionProject === document)
                #expect(AppState.shared.openProjects.contains(where: { $0 === document }))
                #expect(!undo.canUndo)
                try await coordinator.withMutation { _ in }
                let persisted = try await fixture.readPackage()
                #expect(persisted.projectFile.timelines == saved.projectFile.timelines)
                #expect(persisted.manifest == saved.manifest)
                let timeline = try await client.callTool(name: "get_timeline")
                #expect(timeline.isError != true)
                await coordinator.waitUntilIdle()
            }
        }
    }

    @Test func cancellationWhileDrainingLateSaveReopensWithoutClosing() async throws {
        try await withPackageTestFixture { fixture in
            let document = FencedCloseDocument(registry: fixture.registry)
            configure(document, fixture: fixture)
            defer { document.releaseFence() }
            try await savePackageTestDocument(document)
            let closing = Task { try await document.closeAfterSaving() }
            await document.fenceEntered.wait()
            closing.cancel()
            document.releaseFence()
            await #expect(throws: CancellationError.self) { try await closing.value }
            await document.queuedSaveCompleted.wait()
            let coordinator = document.editorViewModel.projectPackageCoordinator
            #expect(!coordinator.isClosing)
            #expect(!coordinator.isClosed)
            try await coordinator.withMutation { _ in }
            await coordinator.waitUntilIdle()
            #expect(try await fixture.readPackage().projectFile.timelines.count == 1)
        }
    }

    @Test func nativeCloseWaitsForLateSaveBeforeRemovingDocument() async throws {
        try await withPackageTestFixture { fixture in
            let document = FencedCloseDocument(registry: fixture.registry)
            configure(document, fixture: fixture)
            try await savePackageTestDocument(document)
            NSDocumentController.shared.addDocument(document)
            defer {
                document.releaseFence()
                NSDocumentController.shared.removeDocument(document)
            }
            document.close()
            await document.fenceEntered.wait()
            #expect(!document.editorViewModel.projectPackageCoordinator.isClosed)
            #expect(AppState.shared.openProjects.contains(where: { $0 === document }))
            document.releaseFence()
            await document.closeCompleted.wait()
            #expect(document.editorViewModel.projectPackageCoordinator.isClosed)
            #expect(!AppState.shared.openProjects.contains(where: { $0 === document }))
            #expect(document.queuedSaveError == nil)
            #expect(try await fixture.readPackage().projectFile.timelines.count == 1)
        }
    }

    private func configure(_ document: VideoProject, fixture: PackageTestFixture) {
        document.fileURL = fixture.package
        document.fileType = VideoProject.typeIdentifier
        document.editorViewModel.projectURL = fixture.package
    }

    private func withClient(
        document: VideoProject, registry: ProjectRegistry,
        operation: @MainActor (Client, ToolExecutor) async throws -> Void
    ) async throws {
        NSDocumentController.shared.addDocument(document)
        defer { NSDocumentController.shared.removeDocument(document) }
        let executor = ToolExecutor(projectProvider: { document }, stockProviders: [], projectRegistry: registry)
        let server = Server(name: "project-close-proof", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "project-close-proof", version: "1")
        do {
            try await server.start(transport: transports.server)
            _ = try await client.connect(transport: transports.client)
            try await operation(client, executor)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func payload(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        for content in result.content {
            if case .text(let text, _, _) = content {
                return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
