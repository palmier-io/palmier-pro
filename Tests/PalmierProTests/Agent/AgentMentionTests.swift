import Foundation
import Testing
@testable import PalmierPro

@Suite("AgentService - mentions")
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
        #expect(editor.agentService.draft == "@Interview-Take-V1-00:00:01:00 ")
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
        #expect(editor.agentService.draft == "@Interview-Take-V1-00:00:01:00 ")
    }

    @Test func attachLinkedVideoAndAudioMentionsUseTrackLabelsAndShortNames() {
        let editor = EditorViewModel()
        let asset = MediaAsset(
            id: "asset-video",
            url: URL(fileURLWithPath: "/tmp/interview.mov"),
            type: .video,
            name: "Very Long Interview Take With Lots of Extra Context",
            duration: 5
        )
        editor.importMediaAsset(asset)
        var video = Fixtures.clip(id: "video-clip", mediaRef: asset.id, mediaType: .video, start: 30, duration: 60)
        var audio = Fixtures.clip(id: "audio-clip", mediaRef: asset.id, mediaType: .audio, start: 30, duration: 60)
        video.linkGroupId = "linked-1"
        audio.linkGroupId = "linked-1"
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])

        editor.agentService.attachMentions(forClipIds: ["video-clip", "audio-clip"])

        #expect(editor.agentService.mentions.map(\.type) == [.video, .audio])
        #expect(editor.agentService.draft == "@Very-Long-Interview-Take-V1-00:00:01:00 @Very-Long-Interview-Take-A1-00:00:01:00 ")
    }

    @Test func attachTimelineRangeMentionAddsStructuredRangeReference() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30)
        editor.setTimelineRange(startFrame: 90, endFrame: 30)

        editor.agentService.attachSelectedTimelineRangeMention()

        #expect(editor.agentService.mentions.count == 1)
        let mention = editor.agentService.mentions[0]
        #expect(mention.mediaRef == nil)
        #expect(mention.type == nil)
        #expect(mention.clipId == nil)
        #expect(mention.referencesTimelineRange)
        #expect(mention.timelineRange == AgentTimelineRangeMention(
            range: TimelineRangeSelection(startFrame: 30, endFrame: 90),
            fps: 30
        ))
        #expect(editor.agentService.draft == "@Range-00:00:01:00-00:00:03:00 ")
    }

    @Test func attachTimelineRangeMentionDoesNotDuplicateExistingRange() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30)
        editor.setTimelineRange(startFrame: 30, endFrame: 90)

        editor.agentService.attachSelectedTimelineRangeMention()
        editor.agentService.attachSelectedTimelineRangeMention()

        #expect(editor.agentService.mentions.count == 1)
        #expect(editor.agentService.draft == "@Range-00:00:01:00-00:00:03:00 ")
    }

    @Test func attachTimelineRangeMentionIgnoresInvalidRange() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30)
        editor.setTimelineRange(startFrame: 30, endFrame: 30)

        editor.agentService.attachSelectedTimelineRangeMention()

        #expect(editor.agentService.mentions.isEmpty)
        #expect(editor.agentService.draft.isEmpty)
    }

    @Test func timelineRangeMentionSerializesAgentContext() throws {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30)
        editor.setTimelineRange(startFrame: 30, endFrame: 90)
        editor.agentService.attachSelectedTimelineRangeMention()

        let entries = AgentMentionContext.mentionEntries(
            editor.agentService.mentions,
            editor: editor
        )

        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry["mention"] as? String == "@Range-00:00:01:00-00:00:03:00")
        #expect(entry["kind"] as? String == "timelineRange")

        let range = try #require(entry["timelineRange"] as? [String: Any])
        #expect(range["startFrame"] as? Int == 30)
        #expect(range["endFrame"] as? Int == 90)
        #expect(range["durationFrames"] as? Int == 60)
        #expect(range["fps"] as? Int == 30)
        #expect(range["startTimecode"] as? String == "00:00:01:00")
        #expect(range["endTimecode"] as? String == "00:00:03:00")
        #expect(range["durationTimecode"] as? String == "00:00:02:00")
        #expect(range["rangeSemantics"] as? String == "startInclusiveEndExclusive")
        #expect(try JSONSerialization.data(withJSONObject: entries).isEmpty == false)
    }

    @Test func timelineRangeMentionCoexistsWithAssetAndClipMentions() {
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
        editor.setTimelineRange(startFrame: 30, endFrame: 90)

        editor.agentService.attachMention(for: asset)
        editor.agentService.attachMentions(forClipIds: ["clip-1"])
        editor.agentService.attachSelectedTimelineRangeMention()

        let entries = AgentMentionContext.mentionEntries(
            editor.agentService.mentions,
            editor: editor
        )
        let kinds = entries.compactMap { $0["kind"] as? String }
        #expect(kinds == ["mediaAsset", "timelineClip", "timelineRange"])
        #expect(editor.agentService.draft == "@Interview-Take @Interview-Take-V1-00:00:01:00 @Range-00:00:01:00-00:00:03:00 ")
    }

    @Test func timelineRangeMentionRoundTripsThroughChatSessionCodable() throws {
        let mention = AgentMention(
            displayName: "Range-00:00:01:00-00:00:03:00",
            timelineRange: AgentTimelineRangeMention(
                range: TimelineRangeSelection(startFrame: 30, endFrame: 90),
                fps: 30
            )
        )
        let message = AgentMessage(role: .user, blocks: [.text("@Range-00:00:01:00-00:00:03:00 summarize this")], mentions: [mention])
        let session = ChatSession(messages: [message])

        let data = try #require(ChatSessionStore.encodeSession(session))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatSession.self, from: data)

        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0].mentions.first?.timelineRange == mention.timelineRange)
        #expect(decoded.messages[0].mentions.first?.mediaRef == nil)
        #expect(decoded.messages[0].mentions.first?.type == nil)
    }

    @Test func legacyAssetMentionDecodesWithoutTimelineRangeField() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Interview-Take",
          "mediaRef": "asset-video",
          "type": "video",
          "clipId": null
        }
        """

        let mention = try JSONDecoder().decode(AgentMention.self, from: Data(json.utf8))

        #expect(mention.mediaRef == "asset-video")
        #expect(mention.type == .video)
        #expect(mention.timelineRange == nil)
    }

    @Test func referencedMentionsDropsMentionsRemovedFromDraft() {
        let assetMention = AgentMention(displayName: "Interview-Take", mediaRef: "asset-video", type: .video)
        let rangeMention = AgentMention(
            displayName: "Range-00:00:01:00-00:00:03:00",
            timelineRange: AgentTimelineRangeMention(
                range: TimelineRangeSelection(startFrame: 30, endFrame: 90),
                fps: 30
            )
        )

        let referenced = AgentMentionContext.referencedMentions(
            [assetMention, rangeMention],
            in: "Use @Range-00:00:01:00-00:00:03:00 only"
        )

        #expect(referenced == [rangeMention])
    }
}
