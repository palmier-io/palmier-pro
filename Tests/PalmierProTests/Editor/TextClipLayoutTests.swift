import Testing
@testable import PalmierPro

@Suite("EditorViewModel — text clip layout")
@MainActor
struct TextClipLayoutTests {
    @Test func fittingTextPreservesRotationAndFlips() {
        let editor = EditorViewModel()
        var clip = Fixtures.clip(id: "text", mediaRef: "", mediaType: .text, start: 0, duration: 20)
        clip.textContent = "Rotated text"
        clip.transform = Transform(
            centerX: 0.4,
            centerY: 0.6,
            width: 1,
            height: 1,
            rotation: 37,
            flipHorizontal: true,
            flipVertical: true
        )

        let changed = editor.fitTextClipToContentIfNeeded(&clip, canvasW: 1920, canvasH: 1080)

        #expect(changed)
        #expect(clip.transform.rotation == 37)
        #expect(clip.transform.flipHorizontal)
        #expect(clip.transform.flipVertical)
    }
}
