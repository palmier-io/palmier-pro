import Foundation

/// A named directory under ~/Library/Caches/CompositorPro with size/clear helpers.
struct DiskCache: Sendable {
    static let rootDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CompositorPro", isDirectory: true)

    let directory: URL

    init(named name: String) {
        self.init(directory: Self.rootDirectory.appendingPathComponent(name, isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func size() -> Int64 { Self.bytes(at: directory) }

    /// Total size of all files under a directory, recursively.
    static func bytes(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Cache key fragment that busts when the underlying file is replaced.
    static func sizeMtimeTag(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)_\(Int(modified))"
    }

    @concurrent
    static func loadSizeMtimeTag(for url: URL) async -> String {
        sizeMtimeTag(for: url)
    }

    func clear() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    /// Prunes entries older than `maxAgeDays` or if total size exceeds `maxBytes` (evicting oldest first).
    func prune(maxBytes: Int64 = 2_000_000_000, maxAgeDays: Int = 14) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoffDate = Date().addingTimeInterval(-Double(maxAgeDays * 86400))
        var fileMeta: [(url: URL, date: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for url in entries {
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = vals.contentModificationDate,
                  let size = vals.fileSize else { continue }
            let size64 = Int64(size)
            if date < cutoffDate {
                try? fm.removeItem(at: url)
            } else {
                fileMeta.append((url: url, date: date, size: size64))
                totalSize += size64
            }
        }

        if totalSize > maxBytes {
            fileMeta.sort { $0.date < $1.date }
            for item in fileMeta {
                try? fm.removeItem(at: item.url)
                totalSize -= item.size
                if totalSize <= maxBytes { break }
            }
        }
    }
}
