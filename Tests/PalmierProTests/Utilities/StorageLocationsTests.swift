import Foundation
import Testing

@testable import PalmierPro

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
