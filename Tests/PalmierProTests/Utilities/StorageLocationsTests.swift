import Foundation
import Testing

@testable import PalmierPro

/// Unique temporary tree, removed when the test's reference goes out of scope.
private final class Scratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct StorageLocationsTests {
    @Test func usableDirectoryCreatesMissingIntermediates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-locations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("Caches", isDirectory: true)
        #expect(StorageLocations.usableDirectory(at: target) == target)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func usableDirectoryIsNilWhenUnwritable() {
        let target = URL(fileURLWithPath: "/System/PalmierProScratch", isDirectory: true)
        #expect(StorageLocations.usableDirectory(at: target) == nil)
    }

    @Test func isAvailableReportsMissingDirectoriesWithoutCreatingThem() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(StorageLocations.isAvailable(at: missing) == false)
        #expect(FileManager.default.fileExists(atPath: missing.path) == false)
    }

    @Test func isAvailableReportsAWritableDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-present-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(StorageLocations.isAvailable(at: root))
    }

    @Test func isAvailableRejectsAFileMasqueradingAsTheRoot() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(StorageLocations.isAvailable(at: file) == false)
    }

    // MARK: - Path resolution

    @Test func cachesDirectoryFallsBackToSystemDefaultWithoutAnOverride() {
        #expect(StorageLocations.expectedCachesDirectory(forScratchRoot: nil) == StorageLocations.defaultCachesDirectory)
    }

    @Test func cachesDirectoryNestsUnderTheConfiguredRoot() {
        let root = URL(fileURLWithPath: "/Volumes/SSD/Palmier", isDirectory: true)
        #expect(
            StorageLocations.expectedCachesDirectory(forScratchRoot: root)
                == root.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    @Test func directoryUsesTheRootItselfWhenThereIsNoSubdirectory() {
        let root = URL(fileURLWithPath: "/Volumes/SSD/Projects", isDirectory: true)
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        #expect(StorageLocations.directory(forRoot: root, subdirectory: nil, default: fallback) == root)
    }

    @Test func directoryIgnoresTheSubdirectoryWhenNoRootIsConfigured() {
        let fallback = URL(fileURLWithPath: "/fallback", isDirectory: true)
        #expect(StorageLocations.directory(forRoot: nil, subdirectory: "Caches", default: fallback) == fallback)
    }

    // MARK: - Reclaiming abandoned roots

    @Test func switchingRootsQueuesThePreviousTreesForDeletion() {
        let queued = StorageLocations.abandonedDirectories(
            previouslyOwned: ["/old/Caches/PalmierPro", "/old/Support/PalmierPro/Models"],
            currentlyOwned: ["/new/Caches/PalmierPro", "/new/Support/PalmierPro/Models"],
            queued: []
        )
        #expect(queued == ["/old/Caches/PalmierPro", "/old/Support/PalmierPro/Models"])
    }

    @Test func unchangedRootsQueueNothing() {
        let owned = ["/root/Caches/PalmierPro", "/root/Temp"]
        #expect(StorageLocations.abandonedDirectories(previouslyOwned: owned, currentlyOwned: owned, queued: []).isEmpty)
    }

    @Test func failedDeletionsStayQueuedForALaterLaunch() {
        let queued = StorageLocations.abandonedDirectories(
            previouslyOwned: ["/root/Caches/PalmierPro"],
            currentlyOwned: ["/root/Caches/PalmierPro"],
            queued: ["/unplugged/Caches/PalmierPro"]
        )
        #expect(queued == ["/unplugged/Caches/PalmierPro"])
    }

    /// Switching back to a root that is still queued must not delete the tree now in use.
    @Test func switchingBackDropsTheDirectoryFromTheQueue() {
        let queued = StorageLocations.abandonedDirectories(
            previouslyOwned: ["/b/Caches/PalmierPro"],
            currentlyOwned: ["/a/Caches/PalmierPro"],
            queued: ["/a/Caches/PalmierPro"]
        )
        #expect(queued == ["/b/Caches/PalmierPro"])
    }

    /// The reaper deletes these outright, so they must always be app-owned subtrees. Returning a
    /// bare base would make a root change delete all of ~/Library/Caches.
    @Test func ownedDirectoriesOnlyNamesAppSubtreesOfEachBase() {
        let caches = URL(fileURLWithPath: "/base/Caches", isDirectory: true)
        let support = URL(fileURLWithPath: "/base/Support", isDirectory: true)
        let owned = StorageLocations.ownedDirectories(caches: caches, support: support)

        #expect(owned.count == 4)
        #expect(!owned.contains(caches) && !owned.contains(support))
        for url in owned {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            #expect(parent != caches.standardizedFileURL.deletingLastPathComponent())
            #expect(url.path.hasPrefix("/base/"))
        }
        #expect(owned.contains(caches.appendingPathComponent("PalmierPro", isDirectory: true)))
        #expect(owned.contains(support.appendingPathComponent("PalmierPro/Models", isDirectory: true)))
    }

    // MARK: - Deleting abandoned trees

    @Test func reapDeletesAQueuedTreeAndItsContents() throws {
        let scratch = try Scratch()
        let tree = try scratch.directory("Caches/PalmierPro")
        try Data("cached".utf8).write(to: tree.appendingPathComponent("entry.bin"))

        #expect(StorageLocations.reap([tree.path]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: tree.path) == false)
    }

    @Test func reapIgnoresPathsThatAreAlreadyGone() throws {
        let scratch = try Scratch()
        let absent = scratch.root.appendingPathComponent("never-existed", isDirectory: true)
        #expect(StorageLocations.reap([absent.path]).isEmpty)
    }

    /// An unplugged volume fails its delete, and the path has to survive for a later launch.
    @Test func reapKeepsWhatItCouldNotDelete() throws {
        let scratch = try Scratch()
        let locked = try scratch.directory("locked")
        let trapped = try scratch.directory("locked/tree")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(StorageLocations.reap([trapped.path]) == [trapped.path])
        #expect(FileManager.default.fileExists(atPath: trapped.path))
    }

    @Test func reapReportsOnlyTheFailuresFromAMixedBatch() throws {
        let scratch = try Scratch()
        let deletable = try scratch.directory("deletable")
        let locked = try scratch.directory("locked")
        let trapped = try scratch.directory("locked/tree")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(StorageLocations.reap([deletable.path, trapped.path]) == [trapped.path])
        #expect(FileManager.default.fileExists(atPath: deletable.path) == false)
    }

    // MARK: - Sweeping stale scratch

    @Test func sweepRemovesEntriesOlderThanTheCutoffAndKeepsTheRest() throws {
        let scratch = try Scratch()
        let stale = scratch.root.appendingPathComponent("timeline-render.mp4")
        let fresh = scratch.root.appendingPathComponent("trim.mp4")
        try Data("old".utf8).write(to: stale)
        try Data("new".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)], ofItemAtPath: stale.path
        )

        StorageLocations.sweep(scratch.root, before: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60))

        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func sweepRemovesStaleSubdirectoriesWholesale() throws {
        let scratch = try Scratch()
        let staged = try scratch.directory("palmier-model-abc")
        try Data().write(to: staged.appendingPathComponent("weights.bin"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)], ofItemAtPath: staged.path
        )

        StorageLocations.sweep(scratch.root, before: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60))

        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test func sweepOfAMissingDirectoryIsANoOp() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-gone-\(UUID().uuidString)", isDirectory: true)
        StorageLocations.sweep(absent, before: Date())
        #expect(FileManager.default.fileExists(atPath: absent.path) == false)
    }

    // MARK: - Reclaim orchestration

    /// Quitting mid-reap must not strand a tree: the queue has to reach disk before anything is
    /// deleted, so a later launch still knows what to finish.
    @Test func reclaimPersistsTheQueueBeforeDeletingAnything() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))
        var queueWhenDeletionRan: [String]?

        StorageLocations.reclaim(
            currentlyOwned: ["/new/Caches/PalmierPro"],
            previouslyOwned: ["/old/Caches/PalmierPro"],
            defaultLocations: [],
            in: suite,
            deleting: { paths in
                queueWhenDeletionRan = suite.stringArray(forKey: StorageLocations.abandonedDefaultsKey)
                return []
            }
        )

        #expect(queueWhenDeletionRan == ["/old/Caches/PalmierPro"])
    }

    @Test func reclaimRecordsThisLaunchsOwnershipAndClearsADrainedQueue() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))

        StorageLocations.reclaim(
            currentlyOwned: ["/new/Caches/PalmierPro"],
            previouslyOwned: ["/old/Caches/PalmierPro"],
            defaultLocations: [],
            in: suite,
            deleting: { _ in [] }
        )

        #expect(suite.stringArray(forKey: StorageLocations.ownedDefaultsKey) == ["/new/Caches/PalmierPro"])
        #expect(suite.stringArray(forKey: StorageLocations.abandonedDefaultsKey) == [])
    }

    /// A launch that predates this bookkeeping has nothing recorded, so the trees left at the
    /// default locations must still be reclaimed rather than orphaned.
    @Test func reclaimSeedsFromTheDefaultLocationsWhenNothingWasRecorded() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))
        var requested: [String] = []

        StorageLocations.reclaim(
            currentlyOwned: ["/new/Caches/PalmierPro"],
            previouslyOwned: nil,
            defaultLocations: ["/default/Caches/PalmierPro"],
            in: suite,
            deleting: { requested = $0; return [] }
        )

        #expect(requested == ["/default/Caches/PalmierPro"])
    }

    @Test func reclaimPrefersTheRecordedOwnershipOverTheDefaultLocations() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))
        var requested: [String] = []

        StorageLocations.reclaim(
            currentlyOwned: ["/new/Caches/PalmierPro"],
            previouslyOwned: ["/old/Caches/PalmierPro"],
            defaultLocations: ["/default/Caches/PalmierPro"],
            in: suite,
            deleting: { requested = $0; return [] }
        )

        #expect(requested == ["/old/Caches/PalmierPro"])
    }

    /// An unplugged volume fails to delete, so it has to stay queued for a later launch.
    @Test func reclaimKeepsWhatCouldNotBeDeletedQueued() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))

        StorageLocations.reclaim(
            currentlyOwned: ["/new/Caches/PalmierPro"],
            previouslyOwned: ["/unplugged/Caches/PalmierPro"],
            defaultLocations: [],
            in: suite,
            deleting: { $0 }
        )

        #expect(suite.stringArray(forKey: StorageLocations.abandonedDefaultsKey) == ["/unplugged/Caches/PalmierPro"])
    }

    /// Relaunching without changing anything must not queue or delete the tree in use.
    @Test func reclaimDeletesNothingWhenTheRootIsUnchanged() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))
        var requested: [String]?

        StorageLocations.reclaim(
            currentlyOwned: ["/root/Caches/PalmierPro"],
            previouslyOwned: ["/root/Caches/PalmierPro"],
            defaultLocations: [],
            in: suite,
            deleting: { requested = $0; return [] }
        )

        #expect(requested == [])
    }

    // MARK: - Defaults

    @Test func configuredRootRoundTripsThroughDefaults() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))
        let key = "scratch"
        let root = URL(fileURLWithPath: "/Volumes/SSD/Palmier/./nested/..", isDirectory: true)

        StorageLocations.setConfiguredRoot(root, forKey: key, in: suite)
        #expect(StorageLocations.configuredRoot(key, from: suite)?.path == "/Volumes/SSD/Palmier")

        StorageLocations.setConfiguredRoot(nil, forKey: key, in: suite)
        #expect(StorageLocations.configuredRoot(key, from: suite) == nil)
    }

    @Test func anEmptyStoredPathReadsAsNoOverride() throws {
        let suite = try #require(UserDefaults(suiteName: "storage-tests-\(UUID().uuidString)"))
        suite.set("", forKey: "scratch")
        #expect(StorageLocations.configuredRoot("scratch", from: suite) == nil)
    }
}
