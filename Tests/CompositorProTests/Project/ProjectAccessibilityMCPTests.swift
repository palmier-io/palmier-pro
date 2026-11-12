import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Project accessibility MCP", .serialized)
@MainActor
struct ProjectAccessibilityMCPTests {
    @Test func discoveryAndListReadBackIsolatedAccessibilityWithoutEdits() async throws {
        try await withFixture { fixture, registry in
            let before = try await fixture.files.snapshot(fixture)
            let executor = ToolExecutor(projectProvider: { nil }, stockProviders: [], projectRegistry: registry)
            try await withClient(executor) { client in
                let (tools, _) = try await client.listTools()
                let tool = try #require(tools.first { $0.name == "manage_project" })
                let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
                #expect(properties["action"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) == ["list", "open", "create", "close"])
                #expect(properties["id"]?.objectValue?["type"]?.stringValue == "string")
                #expect(properties["name"]?.objectValue?["type"]?.stringValue == "string")

                let result = try await client.callTool(name: "manage_project", arguments: ["action": .string("list")])
                try #require(result.isError != true)
                let payload = try json(result.content)
                let projects = try #require(payload["projects"] as? [[String: Any]])
                let independent = await fixture.files.inventory(fixture)
                #expect(projects.count == fixture.entries.count)
                for entry in fixture.entries {
                    let receipt = try #require(projects.first { $0["id"] as? String == entry.id.uuidString })
                    #expect(receipt["path"] as? String == entry.url.path)
                    #expect(receipt["name"] as? String == entry.name)
                    #expect(receipt["isAccessible"] as? Bool == independent[entry.url])
                    #expect(receipt["isOpen"] as? Bool == false)
                    #expect(receipt["isActive"] as? Bool == false)
                    #expect(receipt["isVisible"] as? Bool == false)
                }
                #expect(independent[fixture.readable] == true)
                #expect(independent[fixture.missing] == false)
                #expect(independent[fixture.unreadable] == false)

                let invalid: [[String: Value]] = [
                    ["action": .string("list"), "path": .string(fixture.readable.path)],
                    ["action": .string("delete")],
                    ["action": .string("open"), "id": .string("not-a-uuid")],
                    ["action": .string("open"), "id": .string(UUID().uuidString)],
                    ["action": .string("open"), "name": .string("Unregistered")],
                    ["action": .string("close"), "id": .string(fixture.entries[0].id.uuidString), "path": .string(fixture.readable.path)],
                    ["action": .int(3)],
                ]
                for arguments in invalid {
                    let refused = try await client.callTool(name: "manage_project", arguments: arguments)
                    #expect(refused.isError == true)
                }
                let selectors: [[String: Value]] = [
                    ["id": .string(fixture.entries[0].id.uuidString)],
                    ["name": .string("readable")],
                ]
                for selector in selectors {
                    var arguments = selector
                    arguments["action"] = .string("close")
                    let refused = try await client.callTool(name: "manage_project", arguments: arguments)
                    #expect(refused.isError == true)
                    #expect(try text(refused.content).contains("Project at \(fixture.readable.path) isn't open."))
                }
            }
            try await registry.flush()
            #expect(registry.entries == fixture.entries)
            #expect(try await fixture.files.snapshot(fixture) == before)
        }
    }

    @Test func registryChangeDuringMCPListRejectsStaleReceipt() async throws {
        try await withFixture { fixture, registry in
            let before = try await fixture.files.snapshot(fixture)
            let gate = ProjectAccessibilityMCPGate()
            let executor = ToolExecutor(
                projectProvider: { nil }, stockProviders: [], projectRegistry: registry,
                projectAccessibilityCheck: gate.check
            )
            try await withClient(executor) { client in
                try await withPendingList(client, gate: gate) { request in
                    let moved = fixture.root.appendingPathComponent("Moved.compositorpro")
                    registry.updateURL(from: fixture.readable, to: moved)
                    try #require(registry.entries.first { $0.id == fixture.entries[0].id }?.url == moved.standardizedFileURL)
                    await gate.release()
                    let result = try await request.value
                    #expect(result.isError == true)
                    #expect(try text(result.content).contains("Project context changed"))
                    try await registry.flush()
                    let persisted = try await fixture.files.readRegistry(fixture.registryURL)
                    #expect(persisted == registry.entries)
                    #expect(persisted.first { $0.id == fixture.entries[0].id }?.url == moved)
                    #expect(await fixture.files.inventory(fixture)[fixture.readable] == true)
                }
            }
            let after = try await fixture.files.snapshot(fixture)
            #expect(after.packages == before.packages)
            #expect(after.items == before.items)
        }
    }

    @Test func cancelledMCPListLeavesRegistryAndPackagesUnchanged() async throws {
        try await withFixture { fixture, registry in
            let before = try await fixture.files.snapshot(fixture)
            let gate = ProjectAccessibilityMCPGate()
            let executor = ToolExecutor(
                projectProvider: { nil }, stockProviders: [], projectRegistry: registry,
                projectAccessibilityCheck: gate.check
            )
            try await withClient(executor) { client in
                try await withPendingList(client, gate: gate) { request in
                    try await client.cancelRequest(request.requestID, reason: "Cancel isolated accessibility check")
                    do {
                        _ = try await request.value
                        throw ProjectAccessibilityMCPFailure.expectedCancellation
                    } catch is CancellationError {}
                    await gate.waitUntilFinished()
                    #expect(await gate.wasCancelled)
                }
            }
            try await registry.flush()
            #expect(registry.entries == fixture.entries)
            #expect(try await fixture.files.snapshot(fixture) == before)
        }
    }

    private func withPendingList(
        _ client: Client, gate: ProjectAccessibilityMCPGate,
        _ operation: @MainActor (RequestContext<CallTool.Result>) async throws -> Void
    ) async throws {
        let request: RequestContext<CallTool.Result> = try await client.callTool(
            name: "manage_project", arguments: ["action": .string("list")]
        )
        await gate.waitUntilEntered()
        do {
            try await operation(request)
        } catch {
            do { try await client.cancelRequest(request.requestID, reason: "Fixture cleanup") }
            catch { Issue.record(error) }
            await gate.release()
            await gate.waitUntilFinished()
            throw error
        }
        await gate.waitUntilFinished()
    }

    private func withClient(_ executor: ToolExecutor, _ operation: @MainActor (Client) async throws -> Void) async throws {
        let server = Server(name: "project-accessibility-proof", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "project-accessibility-proof", version: "1")
        do {
            try await server.start(transport: transports.server)
            _ = try await client.connect(transport: transports.client)
            try await operation(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func withFixture(_ operation: @MainActor (ProjectAccessibilityMCPFixture, ProjectRegistry) async throws -> Void) async throws {
        let files = ProjectAccessibilityMCPFiles()
        let project = ProjectFile(timelines: [Fixtures.timeline()])
        let fixture = try await files.prepare(project)
        let registry = ProjectRegistry(fileURL: fixture.registryURL)
        do {
            try await operation(fixture, registry)
            try await registry.flush()
        } catch {
            do { try await Task { @MainActor in try await registry.flush() }.value }
            catch { Issue.record(error) }
            do { try await files.remove(fixture) }
            catch { Issue.record(error) }
            throw error
        }
        try await files.remove(fixture)
    }

    private func text(_ contents: [Tool.Content]) throws -> String {
        for content in contents {
            if case .text(let text, _, _) = content { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func json(_ contents: [Tool.Content]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(contents).utf8)) as? [String: Any])
    }
}

private struct ProjectAccessibilityMCPFixture: Sendable {
    let root: URL
    let files: ProjectAccessibilityMCPFiles
    let entries: [ProjectEntry]

    var registryURL: URL { root.appendingPathComponent("registry.json") }
    var readable: URL { entries[0].url }
    var missing: URL { entries[1].url }
    var unreadable: URL { entries[2].url }
}

private actor ProjectAccessibilityMCPFiles {
    struct Snapshot: Equatable, Sendable {
        let registry: Data
        let packages: [URL: Data]
        let items: Set<String>
    }

    func prepare(_ project: ProjectFile) throws -> ProjectAccessibilityMCPFixture {
        #expect(!Thread.isMainThread)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AccessibilityMCP-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let date = Date(timeIntervalSince1970: 1)
        let entries = ["Readable", "Missing", "Unreadable"].map {
            ProjectEntry(id: UUID(), url: root.appendingPathComponent($0).appendingPathExtension(Project.fileExtension), createdDate: date, lastOpenedDate: date)
        }
        let fixture = ProjectAccessibilityMCPFixture(root: root, files: self, entries: entries)
        do {
            let data = try JSONEncoder().encode(project)
            for url in [fixture.readable, fixture.unreadable] {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                try data.write(to: url.appendingPathComponent(Project.timelineFilename))
            }
            try JSONEncoder().encode(entries).write(to: fixture.registryURL)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.unreadable.path)
        } catch {
            if fm.fileExists(atPath: fixture.unreadable.path) {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.unreadable.path)
            }
            try fm.removeItem(at: root)
            throw error
        }
        return fixture
    }

    func inventory(_ fixture: ProjectAccessibilityMCPFixture) -> [URL: Bool] {
        #expect(!Thread.isMainThread)
        return Dictionary(uniqueKeysWithValues: fixture.entries.map { entry in
            (entry.url, FileManager.default.isReadableFile(atPath: entry.url.path))
        })
    }

    func snapshot(_ fixture: ProjectAccessibilityMCPFixture) throws -> Snapshot {
        #expect(!Thread.isMainThread)
        let fm = FileManager.default
        let registry = try Data(contentsOf: fixture.registryURL)
        var packages: [URL: Data] = [:]
        let items: Set<String>
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.unreadable.path)
        do {
            for url in [fixture.readable, fixture.unreadable] {
                packages[url] = try Data(contentsOf: url.appendingPathComponent(Project.timelineFilename))
            }
            items = Set(try fm.subpathsOfDirectory(atPath: fixture.root.path))
        } catch {
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.unreadable.path)
            throw error
        }
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.unreadable.path)
        return Snapshot(registry: registry, packages: packages, items: items)
    }

    func readRegistry(_ url: URL) throws -> [ProjectEntry] {
        #expect(!Thread.isMainThread)
        return try JSONDecoder().decode([ProjectEntry].self, from: Data(contentsOf: url))
    }

    func remove(_ fixture: ProjectAccessibilityMCPFixture) throws {
        #expect(!Thread.isMainThread)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.unreadable.path)
        try FileManager.default.removeItem(at: fixture.root)
    }
}

private actor ProjectAccessibilityMCPGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var entered = false
    private var finished = false
    private var released = false
    private(set) var wasCancelled = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func check(_ keys: [ProjectAccessibility.Key]) async throws -> [ProjectAccessibility] {
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                    if wasCancelled { pending.resume(throwing: CancellationError()) }
                    else if released { pending.resume() }
                    else { continuation = pending }
                    entered = true
                    for waiter in entryWaiters { waiter.resume() }
                    entryWaiters.removeAll()
                }
            } onCancel: {
                Task { await self.cancel() }
            }
            let results = try await ProjectAccessibility.check(keys)
            finish()
            return results
        } catch {
            finish()
            throw error
        }
    }

    func waitUntilEntered() async {
        guard !entered, !finished else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    private func cancel() {
        wasCancelled = true
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    private func finish() {
        finished = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        for waiter in finishWaiters { waiter.resume() }
        finishWaiters.removeAll()
    }
}

private enum ProjectAccessibilityMCPFailure: Error {
    case expectedCancellation
}
