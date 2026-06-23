import Foundation
import Testing
@testable import PalmierPro

@Suite("AgentService - terminal hand-off")
@MainActor
struct AgentMentionTests {

    private func videoAsset() -> MediaAsset {
        MediaAsset(
            id: "asset-video",
            url: URL(fileURLWithPath: "/tmp/interview.mov"),
            type: .video,
            name: "Interview Take",
            duration: 5
        )
    }

    @Test func attachMentionTypesAssetReferenceIntoTerminal() {
        let editor = EditorViewModel()
        let asset = videoAsset()
        editor.importMediaAsset(asset)

        var typed = ""
        editor.agentService.terminalTyper = { typed += $0 }
        editor.agentService.attachMention(for: asset)

        #expect(typed == "Interview-Take ")
        #expect(editor.agentPanelVisible)
    }

    @Test func attachClipMentionsTypeClipIds() {
        let editor = EditorViewModel()
        let asset = videoAsset()
        editor.importMediaAsset(asset)
        let clip = Fixtures.clip(id: "clip-1", mediaRef: asset.id, start: 30, duration: 60)
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [clip])])

        var typed = ""
        editor.agentService.terminalTyper = { typed += $0 }
        editor.agentService.attachMentions(forClipIds: ["clip-1", "clip-2"])

        #expect(typed == "clips clip-1, clip-2 ")
    }

    @Test func attachTimelineRangeTypesTimecodeReference() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30)
        editor.setTimelineRange(startFrame: 90, endFrame: 30)  // normalizes to 30–90

        var typed = ""
        editor.agentService.terminalTyper = { typed += $0 }
        editor.agentService.attachSelectedTimelineRangeMention()

        #expect(typed == "the timeline range 00:00:01:00\u{2013}00:00:03:00 ")
    }

    @Test func attachTimelineRangeIgnoresInvalidRange() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30)
        editor.setTimelineRange(startFrame: 30, endFrame: 30)

        var typed = ""
        editor.agentService.terminalTyper = { typed += $0 }
        editor.agentService.attachSelectedTimelineRangeMention()

        #expect(typed.isEmpty)
    }

    @Test func textTypedBeforeTerminalMountsIsBufferedThenFlushed() {
        let editor = EditorViewModel()
        let asset = videoAsset()
        editor.importMediaAsset(asset)

        // No typer yet — should buffer.
        editor.agentService.attachMention(for: asset)

        var typed = ""
        editor.agentService.terminalTyper = { typed += $0 }  // didSet flushes the buffer

        #expect(typed == "Interview-Take ")
    }

    @Test func seedPromptTypesPromptIntoTerminal() {
        let editor = EditorViewModel()
        var typed = ""
        editor.agentService.terminalTyper = { typed += $0 }
        editor.agentService.seedPrompt("Add captions to my timeline.")

        #expect(typed == "Add captions to my timeline.")
        #expect(editor.agentPanelVisible)
    }

    // MARK: - Persisted chat-session shape (still snapshotted by the project document)

    @Test func timelineRangeMentionRoundTripsThroughChatSessionCodable() throws {
        let mention = AgentMention(
            displayName: "Range-00:00:01:00-00:00:03:00",
            timelineRange: AgentTimelineRangeMention(
                range: TimelineRangeSelection(startFrame: 30, endFrame: 90),
                fps: 30
            )
        )
        let message = AgentMessage(role: .user, blocks: [.text("summarize this range")], mentions: [mention])
        let session = ChatSession(messages: [message])

        let data = try #require(ChatSessionStore.encodeSession(session))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatSession.self, from: data)

        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0].mentions.first?.timelineRange == mention.timelineRange)
        #expect(decoded.messages[0].mentions.first?.mediaRef == nil)
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
