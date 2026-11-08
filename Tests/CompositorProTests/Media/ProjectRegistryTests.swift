import Foundation
import Testing
@testable import CompositorPro

@Suite("ProjectRegistry")
@MainActor
struct ProjectRegistryTests {
    @Test func registerAddsNewProject() async throws {
        try await withRegistryFixture { fixture in
            let registry = fixture.registry()
            try await registry.waitUntilLoaded()
            let url = fixture.project("Test")
            registry.register(url)
            #expect(registry.entries.count == 1)
            #expect(registry.entries.first?.url == url.standardizedFileURL)
            try await registry.flush()
        }
    }

    @Test func registerDeduplicatesStandardizedURLsAndPreservesIdentity() async throws {
        try await withRegistryFixture { fixture in
            let url = fixture.project("Test")
            let entry = fixture.entry(url: url)
            try await fixture.files.writeEntries([entry], to: fixture.fileURL)
            let registry = fixture.registry()
            try await registry.waitUntilLoaded()

            registry.register(url.deletingLastPathComponent().appendingPathComponent("./Test.palmier"))

            #expect(registry.entries.count == 1)
            #expect(registry.entries.first?.id == entry.id)
            #expect(registry.entries.first?.createdDate == entry.createdDate)
            #expect(try #require(registry.entries.first).lastOpenedDate > entry.lastOpenedDate)
            try await registry.flush()
        }
    }

    @Test func removeDropsOnlyMatchingEntry() async throws {
        try await withRegistryFixture { fixture in
            let registry = fixture.registry()
            registry.register(fixture.project("First"))
            registry.register(fixture.project("Second"))
            registry.remove(fixture.project("First"))
            try await registry.flush()
            #expect(registry.entries.map(\.url) == [fixture.project("Second")])
            #expect(try await fixture.files.readEntries(from: fixture.fileURL) == registry.entries)
        }
    }

    @Test func deleteBatchRemovesMissingProjectsAndReturnsTheirIDs() async throws {
        try await withRegistryFixture { fixture in
            let registry = fixture.registry()
            registry.register(fixture.project("First"))
            registry.register(fixture.project("Second"))
            try await registry.flush()
            let entries = registry.entries

            let result = await registry.delete(entries)
            try await registry.flush()

            #expect(result.deletedIDs == Set(entries.map(\.id)))
            #expect(result.failedNames.isEmpty)
            #expect(registry.entries.isEmpty)
            #expect(try await fixture.files.readEntries(from: fixture.fileURL).isEmpty)
        }
    }

    @Test func updateURLPreservesIdentityAndBumpsLastOpenedDate() async throws {
        try await withRegistryFixture { fixture in
            let oldURL = fixture.project("Old")
            let entry = fixture.entry(url: oldURL)
            try await fixture.files.writeEntries([entry], to: fixture.fileURL)
            let registry = fixture.registry()
            try await registry.waitUntilLoaded()

            registry.updateURL(from: oldURL, to: fixture.project("New"))
            try await registry.flush()

            let updated = try #require(registry.entries.first)
            #expect(updated.url == fixture.project("New"))
            #expect(updated.id == entry.id)
            #expect(updated.createdDate == entry.createdDate)
            #expect(updated.lastOpenedDate > entry.lastOpenedDate)
            #expect(try await fixture.files.readEntries(from: fixture.fileURL) == [updated])
        }
    }

    @Test(arguments: [false, true])
    func noOpMutationsPreservePersistedBytesAndModificationDate(beforeLoad: Bool) async throws {
        try await withRegistryFixture { fixture in
            let url = fixture.project("Existing")
            let entry = fixture.entry(url: url)
            try await fixture.files.writeEntries([entry], to: fixture.fileURL, prettyPrinted: true)
            let before = try await fixture.files.snapshot(fixture.fileURL)
            let registry = fixture.registry()
            if !beforeLoad { try await registry.waitUntilLoaded() }

            registry.remove(fixture.project("Unknown"))
            registry.updateURL(from: fixture.project("Unknown"), to: fixture.project("Other"))
            registry.updateURL(from: url, to: url.deletingLastPathComponent().appendingPathComponent("./Existing.palmier"))
            try await registry.flush()

            #expect(registry.entries == [entry])
            #expect(try await fixture.files.snapshot(fixture.fileURL) == before)
        }
    }

    @Test func emptyRegistryAndNoOpUpdatesDoNotCreatePersistenceFile() async throws {
        try await withRegistryFixture { fixture in
            let registry = fixture.registry()
            registry.updateURL(from: fixture.project("Unknown"), to: fixture.project("Other"))
            registry.remove(fixture.project("Unknown"))
            try await registry.flush()

            #expect(registry.entries.isEmpty)
            #expect(!registry.isLoading)
            #expect(registry.persistenceError == nil)
            #expect(await fixture.files.exists(fixture.fileURL) == false)
        }
    }

    @Test func queuedMutationsReplayInOrderOnLoadedEntries() async throws {
        try await withRegistryFixture { fixture in
            let existing = fixture.entry(url: fixture.project("Existing"))
            let removed = fixture.entry(url: fixture.project("Removed"))
            try await fixture.files.writeEntries([existing, removed], to: fixture.fileURL)
            let registry = fixture.registry()
            #expect(registry.isLoading)

            registry.updateURL(from: existing.url, to: fixture.project("Renamed"))
            registry.register(fixture.project("Transient"))
            registry.remove(fixture.project("Transient"))
            registry.remove(removed.url)
            registry.register(fixture.project("New"))
            #expect(registry.entries.isEmpty)
            try await registry.flush()

            #expect(registry.entries.map(\.url) == [fixture.project("Renamed"), fixture.project("New")])
            #expect(registry.entries.first?.id == existing.id)
            #expect(try await fixture.files.readEntries(from: fixture.fileURL) == registry.entries)
        }
    }

    @Test func queuedMutationsWithNoNetChangePreservePersistedBytes() async throws {
        try await withRegistryFixture { fixture in
            let existing = fixture.entry(url: fixture.project("Existing"))
            try await fixture.files.writeEntries([existing], to: fixture.fileURL, prettyPrinted: true)
            let before = try await fixture.files.snapshot(fixture.fileURL)
            let registry = fixture.registry()

            registry.register(fixture.project("Transient"))
            registry.remove(fixture.project("Transient"))
            try await registry.flush()

            #expect(registry.entries == [existing])
            #expect(try await fixture.files.snapshot(fixture.fileURL) == before)
        }
    }

    @Test func flushPersistsLatestSnapshotAndReloadPreservesIt() async throws {
        try await withRegistryFixture { fixture in
            let registry = fixture.registry()
            try await registry.waitUntilLoaded()
            for index in 0..<32 { registry.register(fixture.project("Project-\(index)")) }
            registry.updateURL(from: fixture.project("Project-0"), to: fixture.project("Renamed"))
            registry.remove(fixture.project("Project-31"))
            try await registry.flush()

            let reloaded = fixture.registry()
            try await reloaded.waitUntilLoaded()
            #expect(reloaded.entries == registry.entries)
            #expect(reloaded.entries.count == 31)
            #expect(reloaded.entries.first?.url == fixture.project("Renamed"))
            let before = try await fixture.files.snapshot(fixture.fileURL)
            try await reloaded.flush()
            #expect(try await fixture.files.snapshot(fixture.fileURL) == before)
        }
    }

    @Test func corruptLoadIsObservableAndNeverOverwritesExistingBytes() async throws {
        try await withRegistryFixture { fixture in
            let corrupt = Data("not a registry".utf8)
            try await fixture.files.write(corrupt, to: fixture.fileURL)
            let registry = fixture.registry()
            registry.register(fixture.project("Queued"))

            let failure = try await persistenceFailure { try await registry.flush() }

            #expect(failure.code == .loadFailed)
            #expect(registry.persistenceError == failure)
            #expect(!registry.isLoading)
            #expect(registry.entries.isEmpty)
            registry.register(fixture.project("AfterFailure"))
            #expect(try await persistenceFailure { try await registry.flush() } == failure)
            #expect(try await fixture.files.contents(fixture.fileURL) == corrupt)
        }
    }

    @Test func failedLoadRefusesDeletionWithoutTouchingProject() async throws {
        try await withRegistryFixture { fixture in
            try await fixture.files.write(Data("corrupt".utf8), to: fixture.fileURL)
            let entry = fixture.entry(url: fixture.project("Preserved"))
            let contents = Data("PROJECT".utf8)
            try await fixture.files.write(contents, to: entry.url)
            let registry = fixture.registry()

            let result = await registry.delete([entry])

            #expect(result.deletedIDs.isEmpty)
            #expect(result.failedNames == [entry.name])
            #expect(registry.persistenceError?.code == .loadFailed)
            #expect(try await fixture.files.contents(entry.url) == contents)
        }
    }

    @Test func failedWriteRemainsObservableAndFlushRetriesLatestState() async throws {
        try await withRegistryFixture { fixture in
            let registry = fixture.registry()
            try await registry.waitUntilLoaded()
            try await fixture.files.createDirectory(fixture.fileURL)
            let sentinel = fixture.fileURL.appendingPathComponent("preserved")
            try await fixture.files.write(Data("PRESERVED".utf8), to: sentinel)
            registry.register(fixture.project("First"))

            let failure = try await persistenceFailure { try await registry.flush() }

            #expect(failure.code == .writeFailed)
            #expect(registry.persistenceError == failure)
            #expect(try await fixture.files.contents(sentinel) == Data("PRESERVED".utf8))
            try await fixture.files.remove(fixture.fileURL)
            registry.register(fixture.project("Second"))
            registry.remove(fixture.project("First"))
            try await registry.flush()
            #expect(registry.persistenceError == nil)
            #expect(try await fixture.files.readEntries(from: fixture.fileURL).map(\.url) == [fixture.project("Second")])
        }
    }

    @Test func cancellingFlushDoesNotCancelAdmittedPersistence() async throws {
        try await withRegistryFixture { fixture in
            let registry = fixture.registry()
            registry.register(fixture.project("Admitted"))
            let waiter = Task { try await registry.flush() }
            waiter.cancel()

            do {
                try await waiter.value
                throw RegistryTestFailure.expectedCancellation
            } catch is CancellationError {}

            try await registry.flush()
            #expect(registry.persistenceError == nil)
            #expect(try await fixture.files.readEntries(from: fixture.fileURL).map(\.url) == [fixture.project("Admitted")])
        }
    }

    @Test func sortedEntriesAreNewestFirst() async throws {
        try await withRegistryFixture { fixture in
            let old = fixture.entry(url: fixture.project("Old"), date: Date(timeIntervalSince1970: 10))
            let new = fixture.entry(url: fixture.project("New"), date: Date(timeIntervalSince1970: 20))
            try await fixture.files.writeEntries([old, new], to: fixture.fileURL)
            let registry = fixture.registry()
            try await registry.flush()
            #expect(registry.sortedEntries == [new, old])
        }
    }

    @Test func projectEntryDerivesNameFromURL() {
        let entry = ProjectEntry(
            id: UUID(), url: URL(fileURLWithPath: "/MyProject.palmier"),
            createdDate: Date(), lastOpenedDate: Date()
        )
        #expect(entry.name == "MyProject")
    }

    @Test func projectEntryAccessibilityCheckRunsOffMain() async throws {
        try await withRegistryFixture { fixture in
            let present = fixture.entry(url: fixture.project("Present"))
            let absent = fixture.entry(url: fixture.project("Absent"))
            try await fixture.files.write(Data(), to: present.url)
            let results = try await ProjectAccessibility.check([.init(present), .init(absent)])
            #expect(results.map(\.isAccessible) == [true, false])
        }
    }
}

private struct RegistryFixture: Sendable {
    let root: URL
    let files: RegistryTestFiles

    var fileURL: URL { root.appendingPathComponent("registry.json") }
    func project(_ name: String) -> URL { root.appendingPathComponent(name).appendingPathExtension("palmier") }
    @MainActor func registry() -> ProjectRegistry { ProjectRegistry(fileURL: fileURL) }
    func entry(url: URL, date: Date = Date(timeIntervalSince1970: 1)) -> ProjectEntry {
        ProjectEntry(id: UUID(), url: url, createdDate: date, lastOpenedDate: date)
    }
}

private actor RegistryTestFiles {
    struct Snapshot: Equatable, Sendable {
        let data: Data
        let modificationDate: Date?
    }

    func makeRoot() throws -> URL {
        #expect(!Thread.isMainThread)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RegistryProof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func createDirectory(_ url: URL) throws {
        #expect(!Thread.isMainThread)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func write(_ data: Data, to url: URL) throws {
        #expect(!Thread.isMainThread)
        try data.write(to: url)
    }

    func writeEntries(_ entries: [ProjectEntry], to url: URL, prettyPrinted: Bool = false) throws {
        #expect(!Thread.isMainThread)
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        try encoder.encode(entries).write(to: url)
    }

    func readEntries(from url: URL) throws -> [ProjectEntry] {
        #expect(!Thread.isMainThread)
        return try JSONDecoder().decode([ProjectEntry].self, from: Data(contentsOf: url))
    }

    func contents(_ url: URL) throws -> Data {
        #expect(!Thread.isMainThread)
        return try Data(contentsOf: url)
    }

    func snapshot(_ url: URL) throws -> Snapshot {
        #expect(!Thread.isMainThread)
        return try Snapshot(data: Data(contentsOf: url), modificationDate: url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    func exists(_ url: URL) -> Bool {
        #expect(!Thread.isMainThread)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func remove(_ url: URL) throws {
        #expect(!Thread.isMainThread)
        try FileManager.default.removeItem(at: url)
    }
}

@MainActor
private func withRegistryFixture<T>(_ body: @MainActor (RegistryFixture) async throws -> T) async throws -> T {
    let files = RegistryTestFiles()
    let fixture = RegistryFixture(root: try await files.makeRoot(), files: files)
    let result: T
    do { result = try await body(fixture) }
    catch {
        try await files.remove(fixture.root)
        throw error
    }
    try await files.remove(fixture.root)
    return result
}

@MainActor
private func persistenceFailure(_ operation: @MainActor () async throws -> Void) async throws -> ProjectRegistryPersistenceError {
    do { try await operation() }
    catch let error as ProjectRegistryPersistenceError { return error }
    throw RegistryTestFailure.expectedPersistenceError
}

private enum RegistryTestFailure: Error {
    case expectedPersistenceError
    case expectedCancellation
}
