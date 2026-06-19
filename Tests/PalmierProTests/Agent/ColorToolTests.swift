import Testing
@testable import PalmierPro

@MainActor
@Suite("set_blend_mode / set_color_grade tools")
struct ColorToolTests {

    private func harness() -> ToolHarness {
        let clip = Fixtures.clip(id: "v1", mediaType: .video, start: 0, duration: 30)
        return ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
    }

    @Test func setsBlendMode() async {
        let h = harness()
        let r = await h.runRaw("set_blend_mode", args: ["clipId": "v1", "mode": "multiply"])
        #expect(r.isError == false)
        #expect(h.editor.timeline.tracks[0].clips[0].blendMode == .multiply)
    }

    @Test func normalBlendModeClearsToNil() async {
        let h = harness()
        _ = await h.runRaw("set_blend_mode", args: ["clipId": "v1", "mode": "screen"])
        _ = await h.runRaw("set_blend_mode", args: ["clipId": "v1", "mode": "normal"])
        #expect(h.editor.timeline.tracks[0].clips[0].blendMode == nil)
    }

    @Test func unknownBlendModeErrors() async {
        let r = await harness().runRaw("set_blend_mode", args: ["clipId": "v1", "mode": "bogus"])
        #expect(r.isError == true)
    }

    @Test func setsColorGradeFields() async {
        let h = harness()
        let r = await h.runRaw("set_color_grade", args: ["clipId": "v1", "contrast": 30.0, "saturation": -20.0])
        #expect(r.isError == false)
        let g = h.editor.timeline.tracks[0].clips[0].colorGrade
        #expect(g?.contrast == 30)
        #expect(g?.saturation == -20)
    }

    @Test func resetClearsGrade() async {
        let h = harness()
        _ = await h.runRaw("set_color_grade", args: ["clipId": "v1", "contrast": 30.0])
        _ = await h.runRaw("set_color_grade", args: ["clipId": "v1", "reset": true])
        #expect(h.editor.timeline.tracks[0].clips[0].colorGrade == nil)
    }

    @Test func clampsOutOfRangeGrade() async {
        let h = harness()
        _ = await h.runRaw("set_color_grade", args: ["clipId": "v1", "exposure": 999.0])
        #expect(h.editor.timeline.tracks[0].clips[0].colorGrade?.exposure == 100)
    }
}
