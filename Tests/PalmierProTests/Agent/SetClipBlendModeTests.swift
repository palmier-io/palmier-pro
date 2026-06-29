import Foundation
import Testing
@testable import PalmierPro

@Suite("set_clip_properties — blendMode")
@MainActor
struct SetClipBlendModeTests {

    private func harness() -> (ToolHarness, String) {
        let clip = Fixtures.clip(id: "v1", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        return (ToolHarness(timeline: timeline), clip.id)
    }

    private func blendMode(_ h: ToolHarness, _ id: String) -> BlendMode? {
        h.editor.timeline.tracks[0].clips[0].blendMode
    }

    @Test func setsBlendMode() async {
        let (h, id) = harness()
        let r = await h.runRaw("set_clip_properties", args: ["clipIds": [id], "blendMode": "screen"])
        #expect(r.isError == false)
        #expect(blendMode(h, id) == .screen)
    }

    @Test func normalClearsBlendMode() async {
        let (h, id) = harness()
        _ = await h.runRaw("set_clip_properties", args: ["clipIds": [id], "blendMode": "multiply"])
        #expect(blendMode(h, id) == .multiply)
        _ = await h.runRaw("set_clip_properties", args: ["clipIds": [id], "blendMode": "normal"])
        #expect(blendMode(h, id) == nil)
    }

    @Test func invalidBlendModeErrors() async {
        let (h, id) = harness()
        let r = await h.runRaw("set_clip_properties", args: ["clipIds": [id], "blendMode": "glow"])
        #expect(r.isError)
    }

    @Test func rejectedOnAudioClip() async {
        let clip = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])]))
        let r = await h.runRaw("set_clip_properties", args: ["clipIds": ["a1"], "blendMode": "screen"])
        #expect(r.isError)
    }
}
