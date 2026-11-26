import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Pasteboard media")
@MainActor
struct PasteboardMediaTests {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("compositor-paste-test-\(UUID().uuidString)"))
    }

    private func pngData() -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    @Test func readsSupportedFileURLsAndSkipsOthers() throws {
        let board = pasteboard()
        board.clearContents()
        let directory = FileManager.default.temporaryDirectory
        let video = directory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        let text = directory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: video)
        try Data("x".utf8).write(to: text)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: text)
        }
        board.writeObjects([video as NSURL, text as NSURL])

        let media = PasteboardMedia.readable(from: board)
        #expect(media.count == 1)
        guard case .file(let url, let type) = media[0] else { Issue.record("expected file media"); return }
        #expect(url.lastPathComponent == video.lastPathComponent)
        #expect(type == .video)
    }

    @Test func readsCopiedImageData() throws {
        let board = pasteboard()
        board.clearContents()
        board.setData(pngData(), forType: .png)

        let media = PasteboardMedia.readable(from: board)
        #expect(media.count == 1)
        guard case .imageData(let data) = media[0] else { Issue.record("expected image data"); return }
        #expect(!data.isEmpty)
    }

    @Test func nonMediaPasteboardYieldsNothing() {
        let board = pasteboard()
        board.clearContents()
        board.setString("just text", forType: .string)
        #expect(PasteboardMedia.readable(from: board).isEmpty)
    }

    @Test func stagingWritesAReadableImageFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await PasteboardMedia.stageImageData(pngData(), into: directory)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(NSBitmapImageRep(data: try Data(contentsOf: url)) != nil)

        await #expect(throws: CocoaError.self) {
            try await PasteboardMedia.stageImageData(Data("nope".utf8), into: directory)
        }
    }
}
