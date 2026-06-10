import Foundation

/// A named directory under ~/Library/Caches/PalmierPro with size/clear helpers.
struct DiskCache: Sendable {
    static let rootDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro", isDirectory: true)

    let directory: URL

    init(named name: String) {
        directory = Self.rootDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func size() -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clear() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }
}
