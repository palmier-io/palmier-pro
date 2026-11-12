import Foundation
import Testing
@testable import CompositorPro

@Suite("DiskCache")
struct DiskCacheTests {
    private func withTempCache(_ body: (DiskCache, URL) throws -> Void) rethrows {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskCacheTest-\(UUID().uuidString)", isDirectory: true)
        let cache = DiskCache(directory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try body(cache, tempDir)
    }

    @Test func clearRemovesAllFiles() throws {
        try withTempCache { cache, dir in
            let fileA = dir.appendingPathComponent("a.txt")
            let fileB = dir.appendingPathComponent("b.txt")
            try "hello".write(to: fileA, atomically: true, encoding: .utf8)
            try "world".write(to: fileB, atomically: true, encoding: .utf8)
            #expect(cache.size() > 0)

            cache.clear()
            #expect(cache.size() == 0)
        }
    }

    @Test func pruneEvictsOldestFilesWhenSizeExceedsMaxBytes() throws {
        try withTempCache { cache, dir in
            let fileA = dir.appendingPathComponent("old.bin")
            let fileB = dir.appendingPathComponent("new.bin")
            let data1k = Data(repeating: 0x41, count: 1024)
            try data1k.write(to: fileA)
            try data1k.write(to: fileB)

            let oldDate = Date().addingTimeInterval(-100)
            let newDate = Date()
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fileA.path)
            try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: fileB.path)

            cache.prune(maxBytes: 1500, maxAgeDays: 30)

            #expect(!FileManager.default.fileExists(atPath: fileA.path))
            #expect(FileManager.default.fileExists(atPath: fileB.path))
            #expect(cache.size() <= 1500)
        }
    }

    @Test func pruneEvictsFilesOlderThanMaxAge() throws {
        try withTempCache { cache, dir in
            let fileOld = dir.appendingPathComponent("ancient.bin")
            let fileFresh = dir.appendingPathComponent("fresh.bin")
            try "ancient".write(to: fileOld, atomically: true, encoding: .utf8)
            try "fresh".write(to: fileFresh, atomically: true, encoding: .utf8)

            let ancientDate = Date().addingTimeInterval(-15 * 86400) // 15 days old
            try FileManager.default.setAttributes([.modificationDate: ancientDate], ofItemAtPath: fileOld.path)

            cache.prune(maxBytes: 10_000_000, maxAgeDays: 14)

            #expect(!FileManager.default.fileExists(atPath: fileOld.path))
            #expect(FileManager.default.fileExists(atPath: fileFresh.path))
        }
    }
}

