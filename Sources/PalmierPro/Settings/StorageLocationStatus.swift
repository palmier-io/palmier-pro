import Foundation

/// A location the Storage pane lets the user override. Identity stays separate from the
/// displayed title so availability and relaunch decisions never depend on localized copy.
enum StorageLocationKind: CaseIterable {
    case scratch
    case projects

    @MainActor
    var localizedTitle: String {
        switch self {
        case .scratch: L10n.string("Scratch and cache")
        case .projects: L10n.string("Projects")
        }
    }
}

/// What the Storage pane reports about the configured locations.
///
/// Kept out of the view so the relaunch and availability rules stay testable and can't drift
/// from what the pane renders.
struct StorageLocationStatus: Equatable {
    let unavailable: [StorageLocationKind]
    let needsRelaunch: Bool

    /// `resolvedCaches` and `resolvedProjects` are the roots this process settled on at launch.
    /// A relaunch is needed only when the configured locations differ from those.
    init(
        scratchRoot: URL?,
        projectsRoot: URL?,
        unavailable: [StorageLocationKind],
        resolvedCaches: URL = StorageLocations.cachesDirectory,
        resolvedProjects: URL = StorageLocations.projectsDirectory
    ) {
        self.unavailable = unavailable
        guard unavailable.isEmpty else {
            // An unreachable root is reported as unavailable instead, since relaunching
            // won't adopt it and the hint would never clear.
            needsRelaunch = false
            return
        }
        let caches = StorageLocations.expectedCachesDirectory(forScratchRoot: scratchRoot)
        let projects = projectsRoot ?? StorageLocations.defaultProjectsDirectory
        needsRelaunch = caches.standardizedFileURL != resolvedCaches.standardizedFileURL
            || projects.standardizedFileURL != resolvedProjects.standardizedFileURL
    }

    /// Probes each configured root. An unset root uses a system default that is always present,
    /// so only an explicit override can be unavailable. Touches the filesystem — call off-main.
    static func unavailableKinds(
        scratchRoot: URL?,
        projectsRoot: URL?,
        isAvailable: (URL) -> Bool = StorageLocations.isAvailable
    ) -> [StorageLocationKind] {
        let roots: [(StorageLocationKind, URL?)] = [(.scratch, scratchRoot), (.projects, projectsRoot)]
        return roots.compactMap { kind, root in
            guard let root, !isAvailable(root) else { return nil }
            return kind
        }
    }
}
