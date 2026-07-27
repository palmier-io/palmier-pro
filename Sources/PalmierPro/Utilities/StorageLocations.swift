import Foundation

/// User-overridable roots for scratch files, caches, and new projects.
///
/// Resolved once per launch so every consumer agrees on a location for the lifetime of the
/// process — long-lived caches capture their directory at first use, and swapping roots
/// underneath in-flight media work would strand or duplicate entries. Changing a location
/// takes effect on relaunch, where `prepare()` reclaims whatever the previous root held.
enum StorageLocations {
    static let scratchDefaultsKey = "storageScratchRoot"
    static let projectsDefaultsKey = "storageProjectsRoot"
    static let ownedDefaultsKey = "storageOwnedDirectories"
    static let abandonedDefaultsKey = "storageAbandonedDirectories"

    /// Configured scratch override, or nil for the system defaults. Applies on next launch.
    static var configuredScratchRoot: URL? {
        get { configuredRoot(scratchDefaultsKey) }
        set { setConfiguredRoot(newValue, forKey: scratchDefaultsKey) }
    }

    /// Configured projects folder, or nil for `~/Documents/Palmier Pro`. Applies on next launch.
    static var configuredProjectsRoot: URL? {
        get { configuredRoot(projectsDefaultsKey) }
        set { setConfiguredRoot(newValue, forKey: projectsDefaultsKey) }
    }

    // MARK: - System defaults

    static let defaultProjectsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Palmier Pro", isDirectory: true)

    static let defaultCachesDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]

    static let defaultSupportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    // MARK: - Resolved roots

    /// Staging root for intermediate files. Defaults to `$TMPDIR`.
    static let temporaryDirectory = resolved(
        scratchDefaultsKey,
        subdirectory: temporarySubdirectory,
        default: FileManager.default.temporaryDirectory
    )

    /// Base for per-feature cache directories. Defaults to `~/Library/Caches`.
    static let cachesDirectory = resolved(
        scratchDefaultsKey, subdirectory: cachesSubdirectory, default: defaultCachesDirectory
    )

    /// Base for large re-downloadable payloads. Defaults to `~/Library/Application Support`.
    static let supportDirectory = resolved(
        scratchDefaultsKey, subdirectory: supportSubdirectory, default: defaultSupportDirectory
    )

    /// Where new projects are created and the save panel opens.
    static let projectsDirectory = resolved(
        projectsDefaultsKey, subdirectory: nil, default: defaultProjectsDirectory
    )

    // MARK: - App-owned directories

    /// `DiskCache`'s tree of per-feature caches.
    static var diskCacheDirectory: URL {
        cachesDirectory.appendingPathComponent(diskCacheName, isDirectory: true)
    }

    /// Transcript and embedding caches.
    static var subsystemCacheDirectory: URL {
        cachesDirectory.appendingPathComponent(Log.subsystem, isDirectory: true)
    }

    /// Downloaded search models.
    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent(modelsPath, isDirectory: true)
    }

    /// Downloaded sample projects.
    static var samplesDirectory: URL {
        supportDirectory.appendingPathComponent(samplesPath, isDirectory: true)
    }

    /// The app's own trees under a pair of bases. One definition so the reaper can never target a
    /// directory the app doesn't actually own — projects and LUTs are user content and excluded.
    static func ownedDirectories(caches: URL, support: URL) -> [URL] {
        [
            caches.appendingPathComponent(diskCacheName, isDirectory: true),
            caches.appendingPathComponent(Log.subsystem, isDirectory: true),
            support.appendingPathComponent(modelsPath, isDirectory: true),
            support.appendingPathComponent(samplesPath, isDirectory: true),
        ]
    }

    /// Directories this launch owns outright and may delete once a different root takes over.
    static var ownedDirectories: [URL] {
        var owned = ownedDirectories(caches: cachesDirectory, support: supportDirectory)
        if ownsTemporaryDirectory { owned.append(temporaryDirectory) }
        return owned
    }

    /// Trees the app left at the system defaults. With a scratch root configured these are already
    /// abandoned, so a user who switched before this bookkeeping existed still gets them reclaimed
    /// instead of orphaned. `$TMPDIR` is excluded — its contents were never ours alone.
    private static var defaultLocationDirectories: [String] {
        guard configuredScratchRoot != nil else { return [] }
        return ownedDirectories(caches: defaultCachesDirectory, support: defaultSupportDirectory)
            .map(\.standardizedFileURL.path)
    }

    /// True when the temporary root is a configured one. `$TMPDIR` is reaped by the system and
    /// shared with other processes, so nothing there is ours to sweep or delete wholesale.
    private static var ownsTemporaryDirectory: Bool {
        temporaryDirectory.standardizedFileURL != FileManager.default.temporaryDirectory.standardizedFileURL
    }

    // MARK: - Launch

    /// Resolves every root — creating a configured one and falling back if it's unusable — then
    /// reclaims anything abandoned by a root change and sweeps stale scratch files. Performs file
    /// I/O, so call it off the main thread. Feature subdirectories are created by their owners.
    nonisolated static func prepare() {
        _ = ownedDirectories
        _ = projectsDirectory
        reapAbandonedDirectories()
        sweepTemporaryDirectory()
    }

    /// Deletes app-owned directories left at a previously configured root, so switching to a
    /// fast drive actually frees the old one. Failures stay queued for a later launch, which is
    /// how an unplugged volume is eventually reclaimed.
    private static func reapAbandonedDirectories() {
        let current = ownedDirectories.map(\.standardizedFileURL.path)
        let recorded = UserDefaults.standard.stringArray(forKey: ownedDefaultsKey)
        let queued = abandonedDirectories(
            previouslyOwned: recorded ?? defaultLocationDirectories,
            currentlyOwned: current,
            queued: stringArray(abandonedDefaultsKey)
        )
        // Persist the queue before deleting, so quitting mid-reap doesn't lose track of the tree.
        UserDefaults.standard.set(queued, forKey: abandonedDefaultsKey)
        UserDefaults.standard.set(current, forKey: ownedDefaultsKey)
        UserDefaults.standard.set(reap(queued), forKey: abandonedDefaultsKey)
    }

    /// Deletes each path, returning those that survived so they can stay queued. Takes its work
    /// explicitly so the destructive step is exercisable against a scratch tree in tests.
    static func reap(_ paths: [String]) -> [String] {
        let fm = FileManager.default
        var remaining: [String] = []
        for path in paths where fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
            } catch {
                Log.app.warning("could not reclaim abandoned storage: \(path) — \(Log.detail(error))")
                remaining.append(path)
            }
        }
        return remaining
    }

    /// A configured scratch root gets no system reaping, and several files staged there are
    /// deliberately long-lived — renders, trims, and extracted audio are handed out as media.
    /// The cutoff is far past any single session, so nothing an open project references is hit.
    private static func sweepTemporaryDirectory() {
        guard ownsTemporaryDirectory else { return }
        sweep(temporaryDirectory, before: Date(timeIntervalSinceNow: -temporaryFileLifetime))
    }

    /// Deletes entries last modified before `cutoff`. Best effort — an entry still in use fails
    /// its removal and is retried on a later launch.
    static func sweep(_ directory: URL, before cutoff: Date) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Path resolution

    /// Directory a configured root implies. Pure — resolves paths without touching the filesystem.
    static func directory(forRoot root: URL?, subdirectory: String?, default fallback: URL) -> URL {
        guard let root else { return fallback }
        return subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    }

    /// Where `root` would place caches. Compare against `cachesDirectory` to tell whether the
    /// running process already reflects the configured setting.
    static func expectedCachesDirectory(forScratchRoot root: URL?) -> URL {
        directory(forRoot: root, subdirectory: cachesSubdirectory, default: defaultCachesDirectory)
    }

    /// Directories to delete given what a previous launch owned, what this launch owns, and what
    /// is already queued. Pure so the reclaim rule is testable without touching disk.
    static func abandonedDirectories(
        previouslyOwned: [String], currentlyOwned: [String], queued: [String]
    ) -> [String] {
        let current = Set(currentlyOwned)
        return Set(queued).union(previouslyOwned).subtracting(current).sorted()
    }

    /// Creates `url` and confirms it accepts writes. Nil when it can't, so a rejected pick or an
    /// unplugged drive degrades to the system default instead of failing every write.
    static func usableDirectory(at url: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.app.warning("storage root unavailable, using default: \(url.path) — \(Log.detail(error))")
            return nil
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            Log.app.warning("storage root not writable, using default: \(url.path)")
            return nil
        }
        return url
    }

    /// Whether an already-configured root is reachable right now. Unlike `usableDirectory` this
    /// creates nothing, so reporting status never resurrects a folder the user deleted.
    static func isAvailable(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    // MARK: - Defaults access

    static func configuredRoot(_ key: String, from defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setConfiguredRoot(_ url: URL?, forKey key: String, in defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func stringArray(_ key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// No filesystem access at all when the key is unset, so the default configuration can
    /// resolve these roots from any thread without risking a blocking touch.
    private static func resolved(_ key: String, subdirectory: String?, default fallback: URL) -> URL {
        guard let root = configuredRoot(key) else { return fallback }
        let target = directory(forRoot: root, subdirectory: subdirectory, default: fallback)
        return usableDirectory(at: target) ?? fallback
    }

    private static let temporarySubdirectory = "Temp"
    private static let cachesSubdirectory = "Caches"
    private static let supportSubdirectory = "Support"
    private static let diskCacheName = "PalmierPro"
    private static let modelsPath = "PalmierPro/Models"
    private static let samplesPath = "PalmierPro/Samples"
    private static let temporaryFileLifetime: TimeInterval = 7 * 24 * 60 * 60
}
