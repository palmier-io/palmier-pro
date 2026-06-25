import Foundation
import Testing
@testable import PalmierPro

@Suite("AudioImport")
@MainActor
struct AudioImportTests {

    private func editor() -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline()
        return e
    }

    @Test func classifiesAudioExtensions() {
        #expect(ClipType(fileExtension: "mp3") == .audio)
        #expect(ClipType(fileExtension: "wav") == .audio)
        #expect(ClipType(fileExtension: "aac") == .audio)
        #expect(ClipType(fileExtension: "m4a") == .audio)
        #expect(ClipType(fileExtension: "aiff") == .audio)
        #expect(ClipType(fileExtension: "aif") == .audio)
        #expect(ClipType(fileExtension: "aifc") == .audio)
        #expect(ClipType(fileExtension: "flac") == .audio)
        #expect(ClipType(fileExtension: "txt") == nil)
    }

    @Test func importsAifcFromFolder() async throws {
        let e = editor()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aifc-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("voice.aifc"))

        let summary = await e.importFinderItems([root], into: nil)

        #expect(summary.assetCount == 1)
        let imported = try #require(e.mediaAssets.first { $0.name == "voice" })
        #expect(imported.type == .audio)
    }
}
