import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Paste media import")
@MainActor
struct PasteMediaImportTests {
    @Test func pastedImageFileBecomesAmediaAsset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let png = directory.appendingPathComponent("pasted.png")
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: png)

        let board = NSPasteboard(name: NSPasteboard.Name("compositor-paste-import-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([png as NSURL])

        let harness = ToolHarness()
        let before = harness.editor.mediaAssets.count
        harness.editor.pasteMedia(from: board)
        #expect(harness.editor.mediaAssets.count == before + 1)
        #expect(harness.editor.mediaAssets.last?.type == .image)
        #expect(harness.editor.mediaAssets.last?.url.lastPathComponent == "pasted.png")
    }

    @Test func plainTextPasteboardAddsNothing() {
        let board = NSPasteboard(name: NSPasteboard.Name("compositor-paste-text-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("just text", forType: .string)
        let harness = ToolHarness()
        let before = harness.editor.mediaAssets.count
        harness.editor.pasteMedia(from: board)
        #expect(harness.editor.mediaAssets.count == before)
    }
}
