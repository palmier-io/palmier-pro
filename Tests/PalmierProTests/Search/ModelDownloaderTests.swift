import CryptoKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("ModelDownloader — checksum")
struct ModelDownloaderTests {
    @Test func verifyAcceptsMatchAndRejectsMismatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("blob.zip")
        let data = Data("the artifact bytes".utf8)
        try data.write(to: file)
        let realHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        try ModelDownloader.verify(file, sha256: realHash)  // correct hash → no throw

        #expect(throws: ModelDownloader.DownloadError.self) {
            try ModelDownloader.verify(file, sha256: String(repeating: "0", count: 64))
        }
    }
}
