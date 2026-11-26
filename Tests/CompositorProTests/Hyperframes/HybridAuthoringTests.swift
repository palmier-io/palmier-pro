import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Hybrid authoring and frame rendering")
struct HybridAuthoringTests {

    @Test func clipEncodesAndDecodesHTMLProperties() throws {
        var clip = Fixtures.clip(start: 0, duration: 60)
        clip.mediaType = .html
        clip.sourceClipType = .html
        clip.htmlContent = "<div>Hello</div>"
        clip.hyperframesBlockId = "title-reveal"
        clip.hyperframesParameters = ["title": "Swift"]

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.mediaType == .html)
        #expect(decoded.htmlContent == "<div>Hello</div>")
        #expect(decoded.hyperframesBlockId == "title-reveal")
        #expect(decoded.hyperframesParameters?["title"] == "Swift")
    }

    @Test @MainActor func insertsAndUpdatesHybridCompositionClip() throws {
        let editor = EditorViewModel()
        let undo = UndoManager()
        editor.undo.attach(undo)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        let clipId = try editor.insertHybridCompositionClip(
            html: "<h1>Test</h1>",
            blockId: "block-1",
            parameters: ["title": "Initial"],
            trackIndex: 0,
            startFrame: 15,
            durationFrames: 45,
            compositeLayer: .overlay
        )

        let placed = try #require(editor.clipFor(id: clipId))
        #expect(placed.mediaType == .html)
        #expect(placed.startFrame == 15)
        #expect(placed.durationFrames == 45)
        #expect(placed.compositeLayer == .overlay)
        #expect(placed.hyperframesParameters?["title"] == "Initial")

        // Update parameters
        try editor.updateHybridCompositionClip(
            clipId: clipId,
            parameters: ["title": "Updated"],
            html: "<h1>Updated</h1>"
        )

        let updated = try #require(editor.clipFor(id: clipId))
        #expect(updated.hyperframesParameters?["title"] == "Updated")
        #expect(updated.htmlContent == "<h1>Updated</h1>")

        // Undo restores original
        _ = editor.undo.undoLatest()
        let restored = try #require(editor.clipFor(id: clipId))
        #expect(restored.hyperframesParameters?["title"] == "Initial")
    }

    @Test func frameCacheStoresAndRetrieves() async {
        let cache = HybridFrameCache()
        let dummy = HybridCompositionRenderer.renderFallbackBitmap(frame: 0, width: 320, height: 180)

        #expect(await cache.frame(contentHash: 1234, frame: 5, width: 320, height: 180) == nil)

        await cache.store(dummy, contentHash: 1234, frame: 5, width: 320, height: 180)
        let retrieved = await cache.frame(contentHash: 1234, frame: 5, width: 320, height: 180)
        #expect(retrieved != nil)
        #expect(retrieved?.width == 320)
        #expect(retrieved?.height == 180)

        await cache.invalidate(contentHash: 1234)
        #expect(await cache.frame(contentHash: 1234, frame: 5, width: 320, height: 180) == nil)
    }

    @Test @MainActor func toolExecutorHandlesHybridComposition() async throws {
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor)

        // Add hybrid composition
        let addResult = try await executor.addHybridComposition(editor, [
            "html": "<div id='card'>Header</div>",
            "blockId": "test-card",
            "startFrame": 0,
            "durationFrames": 60,
            "compositeLayer": "overlay"
        ])
        #expect(!addResult.isError)

        guard let data = addResult.text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clipId = dict["clipId"] as? String else {
            Issue.record("Failed to parse add_hybrid_composition receipt")
            return
        }

        #expect(dict["compositeLayer"] as? String == "overlay")

        // Update hybrid composition
        let updateResult = try await executor.updateHybridComposition(editor, [
            "clipId": clipId,
            "parameters": ["color": "#ff0000"]
        ])
        #expect(!updateResult.isError)
        #expect(editor.clipFor(id: clipId)?.hyperframesParameters?["color"] == "#ff0000")

        // Render hybrid frame
        let renderResult = try await executor.renderHybridFrame(editor, [
            "clipId": clipId,
            "frame": 10,
            "width": 640,
            "height": 360
        ])
        #expect(!renderResult.isError)
        #expect(renderResult.text.contains("\"rendered\":true") || renderResult.text.contains("\"rendered\": true"))
    }
}

