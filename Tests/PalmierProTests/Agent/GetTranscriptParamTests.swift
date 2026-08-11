import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("get_transcript — param tolerance")
struct GetTranscriptParamTests {
    // Empty timeline so the call returns an empty transcript without needing audio —
    // we only care that key validation accepts (or rejects) the params.

    @Test func toleratesWordTimestampsFromInspectMediaHabit() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let result = await h.runRaw("get_transcript", args: ["wordTimestamps": true])
        #expect(result.isError == false) // words are the default; the key must not hard-fail
    }

    @Test func stillRejectsGenuinelyUnknownKeys() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let result = await h.runRaw("get_transcript", args: ["bogusKey": true])
        #expect(result.isError == true)
    }

    @Test func resolvesTrackIndexToStableTrackAndClipIds() throws {
        let first = Fixtures.clip(id: "first", mediaType: .audio, start: 0, duration: 30)
        let second = Fixtures.clip(id: "second", mediaType: .audio, start: 30, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(id: "first-track", clips: [first]),
            Fixtures.audioTrack(id: "second-track", clips: [second]),
        ]))

        let scope = try h.executor.resolveTranscriptionScope(
            h.editor,
            ["trackIndex": 1],
            path: "get_transcript"
        )

        #expect(scope == .track(id: "second-track"))
        #expect(scope.targets(in: h.editor).map(\.id) == ["second"])
        #expect(scope.captionRequest(in: h.editor, provider: .cloud).sourceClipIds == ["second"])
    }

    @Test func explicitClipScopeCanChooseNonMasterMulticamMic() throws {
        var masterClip = Fixtures.clip(id: "master", mediaRef: "lapel", mediaType: .audio, start: 0, duration: 100)
        var roomClip = Fixtures.clip(id: "room", mediaRef: "room", mediaType: .audio, start: 0, duration: 100)
        masterClip.multicamGroupId = "group"
        roomClip.multicamGroupId = "group"
        let master = MulticamSource.Member(
            id: "master-member",
            mediaRef: "lapel",
            kind: .mic,
            angleLabel: "lapel",
            sync: .init(confidence: 1)
        )
        let room = MulticamSource.Member(
            mediaRef: "room",
            kind: .mic,
            angleLabel: "room",
            sync: .init(confidence: 1)
        )
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(id: "master-track", clips: [masterClip]),
            Fixtures.audioTrack(id: "room-track", clips: [roomClip]),
        ]))
        h.editor.multicamGroups = [MulticamSource(
            id: "group",
            name: "Interview",
            members: [master, room],
            masterMemberId: master.id
        )]

        let scope = try h.executor.resolveTranscriptionScope(
            h.editor,
            ["clipId": "room"],
            path: "get_transcript"
        )

        #expect(scope == .clips(ids: ["room"]))
        #expect(scope.targets(in: h.editor).map(\.id) == ["room"])
    }

    @Test func trackIndexValidationIsSharedByTranscriptAndCaptions() async {
        let h = ToolHarness(timeline: Fixtures.timeline())

        let transcript = await h.runRaw("get_transcript", args: ["trackIndex": 4])
        let captions = await h.runRaw("add_captions", args: ["trackIndex": 4])

        #expect(transcript.isError)
        #expect(captions.isError)
        #expect(ToolHarness.textOf(transcript).contains("out of range"))
        #expect(ToolHarness.textOf(captions).contains("out of range"))
    }

    @Test func trackIndexRejectsFractionalNumbers() async {
        let clip = Fixtures.clip(id: "voice", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])]))

        let result = await h.runRaw("get_transcript", args: ["trackIndex": 0.5])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("must be an integer"))
    }

    @Test func trackIndexAndClipIdAreMutuallyExclusive() async {
        let clip = Fixtures.clip(id: "voice", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])]))

        let result = await h.runRaw("get_transcript", args: ["trackIndex": 0, "clipId": "voice"])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("either clipId or trackIndex"))
    }

    @Test func videoScopesResolveToLinkedAudioPartners() throws {
        let groupId = "linked"
        var video = Fixtures.clip(id: "video", mediaRef: "media", mediaType: .video, start: 0, duration: 30)
        var audio = Fixtures.clip(id: "audio", mediaRef: "media", mediaType: .audio, start: 0, duration: 30)
        video.linkGroupId = groupId
        audio.linkGroupId = groupId
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))

        // The linked partner shares media and timing, so both the clip and
        // the video track resolve to it instead of erroring.
        let clipScope = try h.executor.resolveTranscriptionScope(
            h.editor, ["clipId": "video"], path: "get_transcript"
        )
        #expect(clipScope == .clips(ids: ["audio"]))

        let trackScope = try h.executor.resolveTranscriptionScope(
            h.editor, ["trackIndex": 0], path: "get_transcript"
        )
        #expect(trackScope == .clips(ids: ["audio"]))
    }

    @Test func untranscribableScopeWithoutLinkedAudioStillErrors() async {
        let still = Fixtures.clip(id: "still", mediaRef: "media", mediaType: .image, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [still]),
        ]))

        let byClip = await h.runRaw("get_transcript", args: ["clipId": "still"])
        #expect(byClip.isError)
        #expect(ToolHarness.textOf(byClip).contains("no transcribable audio"))

        let byTrack = await h.runRaw("get_transcript", args: ["trackIndex": 0])
        #expect(byTrack.isError)
        #expect(ToolHarness.textOf(byTrack).contains("no transcribable audio"))
    }

    @Test func toleratesZeroFilledFrameWindow() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let result = await h.runRaw(
            "get_transcript",
            args: ["startFrame": 0, "endFrame": 0, "granularity": "segments"]
        )
        #expect(result.isError == false)
    }

    @Test func transcriptSessionReplacesPriorTrackScope() async {
        let clip = Fixtures.clip(id: "voice", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(id: "voice-track", clips: [clip]),
        ]))

        let selected = await h.runRaw("get_transcript", args: ["trackIndex": 0])
        #expect(!selected.isError)
        #expect(h.executor.lastTranscriptSession?.scope == .track(id: "voice-track"))
        #expect(h.executor.lastTranscriptSession?.timelineId == h.editor.activeTimelineId)

        let automatic = await h.runRaw("get_transcript")
        #expect(!automatic.isError)
        #expect(h.executor.lastTranscriptSession?.scope == .automatic)
        #expect(h.executor.lastTranscriptSession?.timelineId == h.editor.activeTimelineId)
    }

    @Test func transcriptAndCaptionSchemasExposeTrackIndex() throws {
        for name in [ToolName.getTranscript, .addCaptions] {
            let tool = try #require(ToolDefinitions.mcpServer.first { $0.name == name })
            let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
            #expect(properties["trackIndex"]?["type"] as? String == "integer")
        }
    }

    @Test func addCaptionsSchemaExposesMaximumGapSeconds() throws {
        let tool = try #require(ToolDefinitions.mcpServer.first { $0.name == .addCaptions })
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        let maximumGap = try #require(properties["maximumGapSeconds"])

        #expect(maximumGap["type"] as? String == "number")
        #expect(maximumGap["minimum"] as? Double == CaptionGapSettings.maximumGapRange.lowerBound)
        #expect(maximumGap["maximum"] as? Double == CaptionGapSettings.maximumGapRange.upperBound)
    }

    @Test func addCaptionsSchemaExposesLengthLimits() throws {
        let tool = try #require(ToolDefinitions.mcpServer.first { $0.name == .addCaptions })
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])

        for key in ["maxWords", "maxCharacters"] {
            #expect(properties[key]?["type"] as? String == "integer")
            #expect(properties[key]?["minimum"] as? Int == 1)
        }
    }

    @Test func addCaptionsRejectsInvalidMaxCharactersBeforeTranscription() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let invalidValues: [Any] = [0, -1, 1.5, "10", true]

        for value in invalidValues {
            let result = await h.runRaw("add_captions", args: ["maxCharacters": value])
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("maxCharacters"))
        }
    }

    @Test func addCaptionsRejectsInvalidMaximumGapSecondsBeforeTranscription() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let invalidValues: [Any] = [-0.1, 2.1, "0.25", true, Double.infinity]

        for value in invalidValues {
            let result = await h.runRaw("add_captions", args: ["maximumGapSeconds": value])
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("maximumGapSeconds"))
        }
    }

    @Test func segmentsGranularityDeclaresSegmentFormat() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let json = try await h.runOK("get_transcript", args: ["granularity": "segments"]) as? [String: Any]
        #expect(json?["segmentFormat"] as? [String] == ["firstWordIndex", "text", "start", "end"])
        #expect(json?["wordFormat"] == nil)
        #expect(await h.runRaw("get_transcript", args: ["granularity": "sentences"]).isError)
    }

    @Test func usesNestedWordShape() async throws {
        // Words nest under clips with a hoisted wordFormat; there is no top-level words array.
        let h = ToolHarness(timeline: Fixtures.timeline())
        let json = try await h.runOK("get_transcript") as? [String: Any]
        #expect(json?["wordFormat"] as? [String] == ["index", "text", "start"])
        #expect(json?["clips"] is [[String: Any]])
        #expect(json?["words"] == nil)
    }

    @Test func cloudTranscriptionRequiresCoveredUncachedCost() {
        #expect(ToolExecutor.canUseCloudTranscription(isSignedIn: true, remainingCredits: 5, estimatedCost: 6) == false)
        #expect(ToolExecutor.canUseCloudTranscription(isSignedIn: true, remainingCredits: 6, estimatedCost: 6) == true)
        #expect(ToolExecutor.canUseCloudTranscription(isSignedIn: true, remainingCredits: 0, estimatedCost: 0) == true)
        #expect(ToolExecutor.canUseCloudTranscription(isSignedIn: false, remainingCredits: 100, estimatedCost: 1) == false)
    }

    @Test func wordRowsSpeakerRunsAndSegments() async throws {
        func w(_ i: Int, _ text: String, _ start: Int, _ end: Int, _ speaker: String?) -> TimelineWord {
            TimelineWord(index: i, clipId: "c1", trackIndex: 0, clipStartFrame: 0, clipEndFrame: 300,
                         text: text, startFrame: start, endFrame: end, speaker: speaker)
        }
        let transcript = TimelineTranscript(
            context: .init(provider: .local, preferredLocale: nil),
            words: [
                w(0, "Hello", 0, 10, "S1"), w(1, "there.", 10, 20, "S1"),
                w(2, "Hi", 60, 70, "S2"), w(3, "back.", 70, 80, "S2"),
                w(4, "Great", 90, 100, "S1"),
            ],
            skipped: []
        )

        let words = transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100)
        #expect(words["wordFormat"] as? [String] == ["index", "text", "start"])
        let rows = ((words["clips"] as? [[String: Any]])?.first?["words"]) as? [[Any]]
        #expect(rows?.count == 5)
        #expect(rows?.first?.count == 3) // no per-word end, no speaker column
        // Speakers arrive as run-length turns keyed by word index.
        let runs = words["speakers"] as? [[Any]]
        #expect(runs?.count == 3)
        #expect(runs?[1][0] as? Int == 2)
        #expect(runs?[1][1] as? String == "S2")

        let segs = transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100, segments: true)
        let segRows = ((segs["clips"] as? [[String: Any]])?.first?["segments"]) as? [[Any]]
        // Sentence end, speaker change, and trailing run each flush: 3 segments.
        #expect(segRows?.count == 3)
        #expect(segRows?.first?[1] as? String == "Hello there.")
        #expect(segRows?.first?[0] as? Int == 0)   // firstWordIndex handle
        #expect(segRows?.first?[3] as? Int == 20)  // segment end retains real end frames
    }
}
