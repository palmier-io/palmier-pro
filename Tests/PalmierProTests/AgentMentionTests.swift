import Foundation
import Testing
@testable import PalmierPro

@Suite("AgentService - clip mentions")
@MainActor
struct AgentMentionTests {

    @Test func attachClipMentionAddsTimelineClipReference() {
        let editor = EditorViewModel()
        let asset = MediaAsset(
            id: "asset-video",
            url: URL(fileURLWithPath: "/tmp/interview.mov"),
            type: .video,
            name: "Interview Take",
            duration: 5
        )
        editor.importMediaAsset(asset)
        let clip = Fixtures.clip(id: "clip-1", mediaRef: asset.id, start: 30, duration: 60)
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])

        editor.agentService.attachMentions(forClipIds: ["clip-1"])

        #expect(editor.agentService.mentions.count == 1)
        #expect(editor.agentService.mentions[0].mediaRef == asset.id)
        #expect(editor.agentService.mentions[0].clipId == "clip-1")
        #expect(editor.agentService.mentions[0].referencesTimelineClips)
        #expect(editor.agentService.draft == "@Interview-Take-00:00:01:00 ")
    }

    @Test func attachClipMentionDoesNotDuplicateExistingClip() {
        let editor = EditorViewModel()
        let asset = MediaAsset(
            id: "asset-video",
            url: URL(fileURLWithPath: "/tmp/interview.mov"),
            type: .video,
            name: "Interview Take",
            duration: 5
        )
        editor.importMediaAsset(asset)
        let clip = Fixtures.clip(id: "clip-1", mediaRef: asset.id, start: 30, duration: 60)
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])

        editor.agentService.attachMentions(forClipIds: ["clip-1"])
        editor.agentService.attachMentions(forClipIds: ["clip-1"])

        #expect(editor.agentService.mentions.count == 1)
        #expect(editor.agentService.draft == "@Interview-Take-00:00:01:00 ")
    }
}
