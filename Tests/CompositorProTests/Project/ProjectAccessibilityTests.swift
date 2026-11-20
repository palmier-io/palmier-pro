import Foundation
import Synchronization
import Testing
@testable import CompositorPro

@Suite("Project accessibility")
struct ProjectAccessibilityTests {
    @MainActor
    @Test func checksRequestedFromMainReadFilesOffMain() async throws {
        let key = makeKey()
        let results = try await ProjectAccessibility.check([key]) { _ in
            #expect(!Thread.isMainThread)
            return true
        }
        #expect(results == [.init(key: key, state: .available)])
    }

    @Test func batchReadsDuplicateURLsOnceAndPreservesExactKeys() async throws {
        let first = makeKey()
        let second = makeKey(url: first.url)
        let probe = AccessibilityReadProbe()

        let results = try await ProjectAccessibility.check([first, second, first], read: probe.read)

        #expect(results.map(\.key) == [first, second, first])
        #expect(results.allSatisfy { $0.isAccessible })
        #expect(await probe.locations() == [first.url])
    }

    @Test func keyChangesOnEitherProjectIDOrURL() {
        let original = makeKey()
        #expect(makeKey(url: original.url) != original)
        let moved = ProjectEntry(
            id: original.id, url: original.url.appendingPathComponent("Moved"),
            createdDate: Date(), lastOpenedDate: Date()
        )
        #expect(ProjectAccessibility.Key(moved) != original)
    }

    @Test(arguments: [CocoaError.Code.fileReadNoSuchFile, .fileNoSuchFile, .fileReadNoPermission, .fileReadUnknown])
    func readFailuresDistinguishMissingFromUnavailable(code: CocoaError.Code) async throws {
        let key = makeKey()
        let result = try await ProjectAccessibility.check([key]) { _ in throw CocoaError(code) }
        let expected: ProjectAccessibility.State = code == .fileReadNoSuchFile || code == .fileNoSuchFile
            ? .missing : .unavailable
        #expect(result == [.init(key: key, state: expected)])
        #expect(result.first?.isAccessible == false)
    }

    @Test func unreadableOrRemoteLocationsAreUnavailable() async throws {
        let file = makeKey()
        let remote = makeKey(url: try #require(URL(string: "https://example.invalid/project.compositorpro")))
        let probe = AccessibilityReadProbe()
        let unreadable = try await ProjectAccessibility.check([file]) { _ in false }
        let unsupported = try await ProjectAccessibility.check([remote], read: probe.read)
        #expect(unreadable == [.init(key: file, state: .unavailable)])
        #expect(unsupported == [.init(key: remote, state: .unavailable)])
        #expect(await probe.locations().isEmpty)
    }

    @Test func freshBatchDetectsFileRemovalAndRestorationWithoutCachedMetadata() async throws {
        let files = AccessibilityTestFiles()
        let root = try await files.makeRoot()
        let url = root.appendingPathComponent("Project.compositorpro", isDirectory: true)
        let key = makeKey(url: url)
        do {
            try await files.createDirectory(url)
            #expect(try await ProjectAccessibility.check([key]).first?.state == .available)
            try await files.remove(url)
            #expect(try await ProjectAccessibility.check([key]).first?.state == .missing)
            try await files.createDirectory(url)
            #expect(try await ProjectAccessibility.check([key]).first?.state == .available)
        } catch {
            try await files.remove(root)
            throw error
        }
        try await files.remove(root)
    }

    @Test func cancellationBetweenReadsStopsBatchAndReleasesGate() async throws {
        let first = makeKey()
        let second = makeKey()
        let probe = AccessibilityReadProbe()
        let task = Task {
            try await ProjectAccessibility.check([first, second]) { url in
                let readable = probe.read(url)
                withUnsafeCurrentTask { $0?.cancel() }
                return readable
            }
        }
        do {
            _ = try await task.value
            throw AccessibilityTestFailure.expectedCancellation
        } catch is CancellationError {}

        #expect(await probe.locations() == [first.url])
        #expect(try await ProjectAccessibility.check([second]) { _ in true }.first?.isAccessible == true)
    }

    @Test func thrownCancellationDoesNotBecomeUnavailableResult() async throws {
        let key = makeKey()
        do {
            _ = try await ProjectAccessibility.check([key]) { _ in throw CancellationError() }
            throw AccessibilityTestFailure.expectedCancellation
        } catch is CancellationError {}
        #expect(try await ProjectAccessibility.check([]).isEmpty)
    }

    @Test func projectListContextRejectsRegistryURLOrDocumentIdentityChanges() {
        let first = NSObject()
        let second = NSObject()
        let key = makeKey()
        let entry = ProjectEntry(id: key.id, url: key.url, createdDate: Date(), lastOpenedDate: Date())
        let document = ProjectListContext.Document(identity: ObjectIdentifier(first), url: key.url)
        let original = ProjectListContext(entries: [entry], open: [document], active: document, visible: document)
        var renamed = entry
        renamed.url = key.url.appendingPathComponent("Moved")
        let replacement = ProjectListContext.Document(identity: ObjectIdentifier(second), url: key.url)
        let changedURL = ProjectListContext.Document(identity: document.identity, url: renamed.url)

        #expect(original != ProjectListContext(entries: [renamed], open: [document], active: document, visible: document))
        #expect(original != ProjectListContext(entries: [entry], open: [replacement], active: replacement, visible: replacement))
        #expect(original != ProjectListContext(entries: [entry], open: [changedURL], active: changedURL, visible: changedURL))
        #expect(original != ProjectListContext(entries: [entry], open: [document], active: nil, visible: document))
        #expect(original != ProjectListContext(entries: [entry], open: [document], active: document, visible: nil))
    }

    @MainActor
    @Test(arguments: [false, true])
    func selectorsAwaitInjectedRegistryBeforeResolving(useID: Bool) async throws {
        let files = AccessibilityTestFiles()
        let root = try await files.makeRoot()
        let entry = ProjectEntry(
            id: UUID(), url: root.appendingPathComponent("Restored.compositorpro"),
            createdDate: Date(), lastOpenedDate: Date()
        )
        let fileURL = root.appendingPathComponent("registry.json")
        do { try await files.writeRegistry([entry], to: fileURL) }
        catch {
            try await files.remove(root)
            throw error
        }
        let registry = ProjectRegistry(fileURL: fileURL)
        let executor = ToolExecutor(projectProvider: { nil }, stockProviders: [], projectRegistry: registry)
        do {
            #expect(registry.isLoading)
            let selector: ToolExecutor.ProjectSelector = useID ? .id(entry.id) : .name("restored")
            #expect(try await executor.resolveProjectURL(selector) == entry.url)
            #expect(!registry.isLoading)
        } catch {
            do { try await registry.flush() }
            catch { Issue.record(error) }
            do { try await files.remove(root) }
            catch { Issue.record(error) }
            throw error
        }
        try await registry.flush()
        try await files.remove(root)
    }

    @MainActor
    @Test func standaloneExecutorPathResolutionRequiresNoRegistryDependency() async throws {
        let executor = ToolExecutor(projectProvider: { nil }, stockProviders: [])
        #expect(executor.projectRegistry == nil)
        #expect(executor.projectAccessibilityCheck == nil)
        let path = "/fixture-\(UUID().uuidString).compositorpro"
        #expect(try await executor.resolveProjectURL(.path(path)) == URL(fileURLWithPath: path))
    }

    @MainActor
    @Test(arguments: [false, true])
    func registryRebaseMatchesDecodedDirectoryHintBeforeOrAfterLoading(beforeLoad: Bool) async throws {
        try await withRegistryDirectoryFixture { registry, fixture, files in
            if beforeLoad { #expect(registry.isLoading) }
            else { try await registry.waitUntilLoaded() }

            registry.updateURL(from: fixture.directoryURL, to: fixture.destinationURL)
            try await registry.flush()

            let updated = try #require(registry.entries.first)
            #expect(updated.id == fixture.entry.id)
            #expect(updated.createdDate == fixture.entry.createdDate)
            #expect(updated.lastOpenedDate > fixture.entry.lastOpenedDate)
            #expect(updated.url.path == fixture.destinationURL.path)
            #expect(try await files.readRegistry(fixture.registryURL) == [updated])
        }
    }

    enum RegistryLocationOperation: CaseIterable, Sendable {
        case lookup
        case register
        case remove
        case unchangedRebase
    }

    @MainActor
    @Test(arguments: RegistryLocationOperation.allCases)
    func registryLocationIdentityIgnoresDecodedDirectoryHint(operation: RegistryLocationOperation) async throws {
        try await withRegistryDirectoryFixture { registry, fixture, files in
            try await registry.waitUntilLoaded()
            let before = try await files.registrySnapshot(fixture.registryURL)
            switch operation {
            case .lookup:
                #expect(registry.id(for: fixture.directoryURL) == fixture.entry.id)
            case .register:
                registry.register(fixture.directoryURL)
                #expect(registry.entries.count == 1)
                #expect(registry.entries.first?.id == fixture.entry.id)
                #expect(registry.entries.first?.createdDate == fixture.entry.createdDate)
            case .remove:
                registry.remove(fixture.directoryURL)
                #expect(registry.entries.isEmpty)
            case .unchangedRebase:
                registry.updateURL(from: fixture.entry.url, to: fixture.directoryURL)
                #expect(registry.entries == [fixture.entry])
            }
            try await registry.flush()
            #expect(try await files.readRegistry(fixture.registryURL) == registry.entries)
            if operation == .lookup || operation == .unchangedRebase {
                #expect(try await files.registrySnapshot(fixture.registryURL) == before)
            }
        }
    }

    @MainActor
    private func withRegistryDirectoryFixture(
        _ operation: @MainActor (ProjectRegistry, AccessibilityRegistryDirectoryFixture, AccessibilityTestFiles) async throws -> Void
    ) async throws {
        let files = AccessibilityTestFiles()
        let fixture = try await files.makeRegistryDirectoryFixture()
        let registry = ProjectRegistry(fileURL: fixture.registryURL)
        do {
            #expect(!fixture.entry.url.hasDirectoryPath)
            #expect(fixture.directoryURL.hasDirectoryPath)
            #expect(fixture.entry.url.path == fixture.directoryURL.path)
            try await operation(registry, fixture, files)
            try await registry.flush()
        } catch {
            do { try await Task { @MainActor in try await registry.flush() }.value }
            catch { Issue.record(error) }
            do { try await files.remove(fixture.root) }
            catch { Issue.record(error) }
            throw error
        }
        try await files.remove(fixture.root)
    }

    private func makeKey(url: URL = URL(fileURLWithPath: "/project-\(UUID().uuidString).compositorpro")) -> ProjectAccessibility.Key {
        .init(ProjectEntry(id: UUID(), url: url, createdDate: Date(), lastOpenedDate: Date()))
    }
}

private final class AccessibilityReadProbe: Sendable {
    private let reads = Mutex<[URL]>([])

    func read(_ url: URL) -> Bool {
        #expect(!Thread.isMainThread)
        reads.withLock { $0.append(url) }
        return true
    }

    @concurrent func locations() async -> [URL] { reads.withLock { $0 } }
}

private actor AccessibilityTestFiles {
    struct RegistrySnapshot: Equatable, Sendable {
        let data: Data
        let modificationDate: Date?
    }

    func makeRoot() throws -> URL {
        #expect(!Thread.isMainThread)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccessibilityProof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func createDirectory(_ url: URL) throws {
        #expect(!Thread.isMainThread)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove(_ url: URL) throws {
        #expect(!Thread.isMainThread)
        try FileManager.default.removeItem(at: url)
    }

    func writeRegistry(_ entries: [ProjectEntry], to url: URL) throws {
        #expect(!Thread.isMainThread)
        try JSONEncoder().encode(entries).write(to: url)
    }

    func readRegistry(_ url: URL) throws -> [ProjectEntry] {
        #expect(!Thread.isMainThread)
        return try JSONDecoder().decode([ProjectEntry].self, from: Data(contentsOf: url))
    }

    func registrySnapshot(_ url: URL) throws -> RegistrySnapshot {
        #expect(!Thread.isMainThread)
        let freshURL = URL(fileURLWithPath: url.path, isDirectory: false)
        return try RegistrySnapshot(
            data: Data(contentsOf: freshURL),
            modificationDate: freshURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
    }

    func makeRegistryDirectoryFixture() throws -> AccessibilityRegistryDirectoryFixture {
        #expect(!Thread.isMainThread)
        let root = try makeRoot()
        do {
            let url = root.appendingPathComponent("Restored.compositorpro", isDirectory: false)
            let date = Date(timeIntervalSince1970: 1)
            let entry = ProjectEntry(id: UUID(), url: url, createdDate: date, lastOpenedDate: date)
            let registryURL = root.appendingPathComponent("registry.json", isDirectory: false)
            try createDirectory(url)
            try writeRegistry([entry], to: registryURL)
            return AccessibilityRegistryDirectoryFixture(
                root: root, registryURL: registryURL, entry: entry,
                directoryURL: URL(fileURLWithPath: url.path, isDirectory: true),
                destinationURL: root.appendingPathComponent("Renamed.compositorpro", isDirectory: false)
            )
        } catch {
            try remove(root)
            throw error
        }
    }
}

private struct AccessibilityRegistryDirectoryFixture: Sendable {
    let root: URL
    let registryURL: URL
    let entry: ProjectEntry
    let directoryURL: URL
    let destinationURL: URL
}

private enum AccessibilityTestFailure: Error {
    case expectedCancellation
}
