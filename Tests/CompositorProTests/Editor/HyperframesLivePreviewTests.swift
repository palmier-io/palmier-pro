import Foundation
import Testing
@testable import CompositorPro

@Suite("HyperFrames Live Preview")
@MainActor
struct HyperframesLivePreviewTests {

    @Test func previewTabProperties() {
        let html = "<html><body><h1>Hero</h1></body></html>"
        let tab = PreviewTab.hyperframesBlock(
            id: "hero-title-reveal",
            name: "Hero Title Reveal",
            html: html,
            durationFrames: 120
        )

        #expect(tab.id == "hyperframes_hero-title-reveal")
        #expect(tab.displayName == "Hero Title Reveal")
        #expect(tab.isCloseable == true)
        #expect(tab.clipType == .video)
        #expect(tab.underlineColor == AppTheme.Accent.spotlight)
        #expect(tab.isHyperframes == true)
        #expect(tab.hyperframesHTML == html)
        #expect(tab.hyperframesBlockId == "hero-title-reveal")
    }

    @Test func editorViewModelPreviewTabLifecycle() {
        let editor = EditorViewModel()
        #expect(editor.activePreviewTab == .timeline)

        let html = "<html><body><h1>Split Feature</h1></body></html>"
        editor.openHyperframesPreviewTab(
            id: "split-feature-showcase",
            name: "Split Feature Showcase",
            html: html,
            durationFrames: 180
        )

        #expect(editor.activePreviewTabId == "hyperframes_split-feature-showcase")
        #expect(editor.activePreviewTab.isHyperframes == true)
        #expect(editor.activePreviewDurationFrames == 180)
        #expect(editor.sourcePlayheadFrame == 0)

        // Seeking source frame stays within bounds
        editor.seekSourceToFrame(50)
        #expect(editor.sourcePlayheadFrame == 50)

        // Closing the tab restores timeline tab
        editor.closePreviewTab(id: "hyperframes_split-feature-showcase")
        #expect(editor.activePreviewTab == .timeline)
    }

    @Test func coordinatorTracking() {
        let coordinator = HyperframesLivePreviewView.Coordinator()
        #expect(coordinator.lastHTML == nil)
        #expect(coordinator.lastFrame == nil)

        coordinator.lastHTML = "<div>Test</div>"
        coordinator.lastFrame = 45
        #expect(coordinator.lastHTML == "<div>Test</div>")
        #expect(coordinator.lastFrame == 45)
    }

    @Test func toolExecutorPreviewHyperframesBlock() async throws {
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor)

        let result = try await executor.previewHyperframesBlock(editor, [
            "blockId": "badge-pop",
            "parameters": ["title": "New Award"]
        ])

        #expect(!result.isError)
        let json = result.text
        let data = try #require(json.data(using: .utf8))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(dict["status"] as? String == "ok")
        #expect(dict["blockId"] as? String == "badge-pop")
        #expect(dict["blockName"] as? String == "Badge Pop")
        #expect(editor.activePreviewTab.isHyperframes == true)
        #expect(editor.activePreviewTab.hyperframesBlockId == "badge-pop")
        #expect(editor.activePreviewTab.hyperframesHTML?.contains("New Award") == true)
    }
}

