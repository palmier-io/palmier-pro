import Testing
@testable import PalmierPro

@MainActor
@Suite("set_chroma_key tool")
struct ChromaKeyToolTests {

    private func harness() -> ToolHarness {
        let clip = Fixtures.clip(id: "v1", mediaType: .video, start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        return ToolHarness(timeline: timeline)
    }

    @Test func enablesChromaKeyWithGreenDefault() async {
        let h = harness()
        let r = await h.runRaw("set_chroma_key", args: ["clipId": "v1"])
        #expect(r.isError == false)
        let key = h.editor.timeline.tracks[0].clips[0].chromaKey
        #expect(key?.enabled == true)
        #expect(key?.keyColor == TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1))
    }

    @Test func parsesCustomParameters() async {
        let h = harness()
        _ = await h.runRaw("set_chroma_key", args: [
            "clipId": "v1", "keyColorHex": "#0000FF", "tolerance": 60.0, "spill": 10.0,
        ])
        let key = h.editor.timeline.tracks[0].clips[0].chromaKey
        #expect(key?.tolerance == 60)
        #expect(key?.spill == 10)
        #expect(key?.keyColor.b == 1)
        #expect(key?.keyColor.r == 0)
    }

    @Test func disableRemovesKey() async {
        let h = harness()
        _ = await h.runRaw("set_chroma_key", args: ["clipId": "v1"])
        _ = await h.runRaw("set_chroma_key", args: ["clipId": "v1", "enabled": false])
        #expect(h.editor.timeline.tracks[0].clips[0].chromaKey == nil)
    }

    @Test func unknownClipIsError() async {
        let r = await harness().runRaw("set_chroma_key", args: ["clipId": "nope"])
        #expect(r.isError == true)
    }

    @Test func rejectsAudioClip() async {
        let audio = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [audio])]))
        let r = await h.runRaw("set_chroma_key", args: ["clipId": "a1"])
        #expect(r.isError == true)
    }
}
