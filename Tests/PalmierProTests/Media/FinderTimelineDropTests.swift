import AppKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("Finder → timeline drop")
@MainActor
struct FinderTimelineDropTests {

    private func editor() -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        return e
    }

    private func writePNG(to url: URL) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func dropImportsAndPlacesClipAtFrame() async throws {
        let e = editor()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder-drop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("still.png")
        try writePNG(to: file)

        await e.importFinderItemsToTimeline([file], cursor: .existingTrack(0), atFrame: 42, ripple: false)

        let asset = try #require(e.mediaAssets.first { $0.name == "still" })
        let clip = try #require(e.timeline.tracks[0].clips.first)
        #expect(clip.mediaRef == asset.id)
        #expect(clip.startFrame == 42)
    }

    @Test func singleUndoRevertsImportAndPlacement() async throws {
        let e = editor()
        let um = UndoManager()
        e.undo.attach(um)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder-drop-undo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("still.png")
        try writePNG(to: file)

        await e.importFinderItemsToTimeline([file], cursor: .existingTrack(0), atFrame: 0, ripple: false)
        #expect(e.mediaAssets.count == 1)
        #expect(!e.timeline.tracks[0].clips.isEmpty)

        #expect(e.undo.undoLatest() == "Add Media")
        #expect(e.mediaAssets.isEmpty)
        #expect(e.timeline.tracks.allSatisfy { $0.clips.isEmpty })
        #expect(!um.canUndo)
    }

    @Test func unreadableFileImportsWithoutPlacingClip() async throws {
        let e = editor()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder-drop-bad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("broken.mp4")
        try Data().write(to: file)

        await e.importFinderItemsToTimeline([file], cursor: .existingTrack(0), atFrame: 0, ripple: false)

        #expect(e.mediaAssets.count == 1)
        #expect(e.timeline.tracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test func placeholderAssetsSkipFoldersAndUnsupportedTypes() {
        let e = editor()
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/folder", isDirectory: true),
        ]
        let placeholders = e.dropPlaceholderAssets(for: urls)
        #expect(placeholders.map(\.name) == ["a"])
        #expect(placeholders[0].type == .video)
    }
}
