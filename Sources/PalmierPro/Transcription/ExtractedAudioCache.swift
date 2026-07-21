// Persistent cache of extracted 16kHz mono audio (CAF), keyed by source-file identity — a
// transcript cache-tag bump re-runs ASR against this small file instead of re-demuxing the
// source video. Bounded LRU by total bytes; eviction is best-effort and never fails a caller.
import CryptoKit
import Foundation

enum ExtractedAudioCache {
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/ExtractedAudio", isDirectory: true)

    /// ~110MB per hour of source audio at 16k mono 16-bit, so this holds ~35h of extractions.
    static let maxTotalBytes: Int64 = 4 << 30

    static func url(for sourceURL: URL, in directory: URL = directory) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let identity = "pcm16k|\(sourceURL.path)|\(mtime.timeIntervalSince1970)|\(size)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appendingPathComponent("\(key).caf")
    }

    /// The cached extraction for this source, if present. Touches mtime so eviction stays use-ordered.
    static func cached(for sourceURL: URL, in directory: URL = directory) -> URL? {
        guard let target = url(for: sourceURL, in: directory), FileManager.default.fileExists(atPath: target.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        return target
    }

    /// Adopt a freshly extracted temp file into the cache (moves it) and return its cache URL.
    /// On any failure the temp URL is returned unchanged — still a valid transcription input; the
    /// system temp dir owns its cleanup. Callers must not delete the returned URL either way.
    static func adopt(tempURL: URL, for sourceURL: URL, in directory: URL = directory) -> URL {
        guard let target = url(for: sourceURL, in: directory) else { return tempURL }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tempURL, to: target)
        } catch {
            return FileManager.default.fileExists(atPath: tempURL.path) ? tempURL : target
        }
        evictIfNeeded(in: directory)
        return target
    }

    /// Drop least-recently-used entries until the cache is under the byte cap.
    static func evictIfNeeded(cap: Int64 = maxTotalBytes, in directory: URL = directory) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        var files: [(url: URL, bytes: Int64, used: Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let bytes = values.fileSize else { return nil }
            return (url, Int64(bytes), values.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.bytes }
        guard total > cap else { return }
        files.sort { $0.used < $1.used }
        for file in files where total > cap {
            try? fm.removeItem(at: file.url)
            total -= file.bytes
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
