import Foundation
import Testing

@testable import PalmierPro

@Suite struct StorageLocationStatusTests {
    private static let resolvedCaches = URL(fileURLWithPath: "/resolved/Caches", isDirectory: true)
    private static let resolvedProjects = URL(fileURLWithPath: "/resolved/Projects", isDirectory: true)

    private func status(
        scratchRoot: URL? = nil,
        projectsRoot: URL? = nil,
        unavailable: [StorageLocationKind] = []
    ) -> StorageLocationStatus {
        .init(
            scratchRoot: scratchRoot,
            projectsRoot: projectsRoot,
            unavailable: unavailable,
            resolvedCaches: Self.resolvedCaches,
            resolvedProjects: Self.resolvedProjects
        )
    }

    // MARK: - Relaunch

    @Test func aScratchRootThisProcessDidNotResolveNeedsARelaunch() {
        let picked = URL(fileURLWithPath: "/Volumes/SSD/Scratch", isDirectory: true)
        #expect(status(scratchRoot: picked).needsRelaunch)
    }

    @Test func aProjectsRootThisProcessDidNotResolveNeedsARelaunch() {
        let picked = URL(fileURLWithPath: "/Volumes/SSD/Projects", isDirectory: true)
        #expect(status(projectsRoot: picked).needsRelaunch)
    }

    /// The roots this process already resolved, so the hint must not appear.
    @Test func rootsMatchingTheResolvedLocationsNeedNoRelaunch() {
        let scratch = Self.resolvedCaches.deletingLastPathComponent()
        #expect(!status(scratchRoot: scratch, projectsRoot: Self.resolvedProjects).needsRelaunch)
    }

    @Test func unconfiguredRootsNeedNoRelaunchWhenTheDefaultsAreResolved() {
        let defaults = StorageLocationStatus(
            scratchRoot: nil,
            projectsRoot: nil,
            unavailable: [],
            resolvedCaches: StorageLocations.defaultCachesDirectory,
            resolvedProjects: StorageLocations.defaultProjectsDirectory
        )
        #expect(!defaults.needsRelaunch)
    }

    /// Relaunching would never adopt an unreachable root, so nagging for one would never clear.
    @Test func anUnavailableRootReportsUnavailableRatherThanARelaunch() {
        let picked = URL(fileURLWithPath: "/Volumes/Unplugged/Scratch", isDirectory: true)
        let result = status(scratchRoot: picked, unavailable: [.scratch])

        #expect(!result.needsRelaunch)
        #expect(result.unavailable == [.scratch])
    }

    @Test func pathStandardizationDoesNotTriggerARelaunch() {
        let equivalent = URL(fileURLWithPath: "/resolved/./nested/..", isDirectory: true)
        #expect(!status(scratchRoot: equivalent, projectsRoot: Self.resolvedProjects).needsRelaunch)
    }

    // MARK: - Availability

    @Test func anUnsetRootIsNeverReportedUnavailable() {
        let kinds = StorageLocationStatus.unavailableKinds(
            scratchRoot: nil,
            projectsRoot: nil,
            isAvailable: { _ in false }
        )
        #expect(kinds.isEmpty)
    }

    @Test func onlyTheUnreachableRootIsNamed() {
        let offline = URL(fileURLWithPath: "/Volumes/Unplugged", isDirectory: true)
        let online = URL(fileURLWithPath: "/Volumes/Present", isDirectory: true)
        let kinds = StorageLocationStatus.unavailableKinds(
            scratchRoot: offline,
            projectsRoot: online,
            isAvailable: { $0 != offline }
        )
        #expect(kinds == [.scratch])
    }

    @Test func bothRootsCanBeUnavailableAtOnce() {
        let kinds = StorageLocationStatus.unavailableKinds(
            scratchRoot: URL(fileURLWithPath: "/Volumes/A", isDirectory: true),
            projectsRoot: URL(fileURLWithPath: "/Volumes/B", isDirectory: true),
            isAvailable: { _ in false }
        )
        #expect(kinds == [.scratch, .projects])
    }

    @Test func reachableRootsAreNotReported() {
        let kinds = StorageLocationStatus.unavailableKinds(
            scratchRoot: URL(fileURLWithPath: "/Volumes/A", isDirectory: true),
            projectsRoot: URL(fileURLWithPath: "/Volumes/B", isDirectory: true),
            isAvailable: { _ in true }
        )
        #expect(kinds.isEmpty)
    }
}
