import Testing
@testable import PalmierPro

@Suite("Agent activity highlights")
@MainActor
struct AgentActivityHighlightTests {
    private func harnessWithClip(duration: Int = 100) -> (ToolHarness, Clip) {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: duration)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        return (ToolHarness(timeline: timeline), clip)
    }

    @Test func classifierSeparatesAddedAndMutatedClips() {
        let mutated = Fixtures.clip(id: "mutated", start: 0, duration: 10)
        let removed = Fixtures.clip(id: "removed", start: 20, duration: 10)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [mutated, removed]),
        ]))
        let before = harness.editor.timeline
        harness.editor.timeline.tracks[0].clips[0].startFrame = 5
        harness.editor.timeline.tracks[0].clips.removeAll { $0.id == removed.id }
        harness.editor.timeline.tracks[0].clips.append(
            Fixtures.clip(id: "added", start: 30, duration: 10)
        )

        harness.executor.publishAgentChanges(
            before: before,
            after: harness.editor.timeline,
            editor: harness.editor
        )

        #expect(harness.editor.agentActivity.addedClipIds == ["added"])
        #expect(harness.editor.agentActivity.mutatedClipIds == [mutated.id])
        harness.editor.clearAgentActivity()
    }

    @Test func executorHighlightsOnlyActualPropertyChanges() async throws {
        let (harness, clip) = harnessWithClip(duration: 30)
        _ = try await harness.runOK("set_clip_properties", args: [
            "clipIds": [clip.id],
            "opacity": 1.0,
        ])
        #expect(harness.editor.agentActivity.isEmpty)

        _ = try await harness.runOK("set_clip_properties", args: [
            "clipIds": [clip.id],
            "opacity": 0.5,
        ])
        #expect(harness.editor.agentActivity.mutatedClipIds == [clip.id])
        harness.editor.clearAgentActivity()
    }

    @Test func copySettingsHighlightsOnlyChangedTargets() async throws {
        var source = Fixtures.clip(id: "source", start: 0, duration: 30)
        source.opacity = 0.5
        let target = Fixtures.clip(id: "target", start: 40, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [source, target]),
        ]))
        let args: [String: Any] = [
            "sourceClipId": source.id,
            "targetClipIds": [target.id],
        ]

        _ = try await harness.runOK("copy_clip_settings", args: args)
        #expect(harness.editor.agentActivity.mutatedClipIds == [target.id])
        harness.editor.clearAgentActivity()

        _ = try await harness.runOK("copy_clip_settings", args: args)
        #expect(harness.editor.agentActivity.isEmpty)
    }

    @Test func onlyMutationToolsPublishTimelineChanges() {
        let excluded: [ToolName] = [.inspectTimeline, .getTranscript, .organizeMedia]
        let included: [ToolName] = [
            .manageTracks, .setClipProperties, .copyClipSettings, .denoiseAudio, .generateAudio,
        ]
        #expect(excluded.allSatisfy { !$0.publishesTimelineChanges })
        #expect(included.allSatisfy { $0.publishesTimelineChanges })
    }

    @Test func manageTracksHighlightsReorderAndFlagChanges() async throws {
        var first = Fixtures.videoTrack()
        first.id = "first"
        var second = Fixtures.videoTrack()
        second.id = "second"
        var audio = Fixtures.audioTrack()
        audio.id = "audio"
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [first, second, audio]))

        _ = try await harness.runOK("manage_tracks", args: [
            "reorder": [["index": 0, "to": 1]],
            "set": [
                ["index": 0, "hidden": true, "syncLocked": false],
                ["index": 2, "muted": true],
            ],
        ])

        #expect(harness.editor.agentActivity.mutatedTrackIds == [first.id, second.id, audio.id])
        harness.editor.clearAgentActivity()

        _ = try await harness.runOK("manage_tracks", args: ["remove": [0]])
        #expect(harness.editor.agentActivity.isEmpty)
    }

    @Test func mapsOnlyVisibleTimelineReads() {
        let (harness, clip) = harnessWithClip()
        func activity(
            _ tool: ToolName,
            _ args: [String: Any] = [:]
        ) -> AgentActivityHighlight? {
            harness.executor.timelineReadActivity(for: tool, args: args, editor: harness.editor)
        }

        #expect(activity(.inspectMedia, ["clipId": clip.id])?.readClipIds == [clip.id])

        let combinedRead = activity(.getTranscript, [
            "clipId": clip.id,
            "startFrame": 10,
            "endFrame": 20,
        ])
        #expect(combinedRead?.readClipIds == [clip.id])
        #expect(combinedRead?.range == 10..<20)

        let excludedReads = [
            activity(.getMedia),
            activity(.getTimeline),
            activity(.getTimeline, ["startFrame": 0, "endFrame": 0]),
            activity(.getTimeline, ["startFrame": 20, "endFrame": 10]),
            activity(.inspectTimeline, ["startFrame": Int.max]),
            activity(.getTimeline, ["startFrame": 1_000, "endFrame": 2_000]),
        ]
        #expect(excludedReads.allSatisfy { $0 == nil })
    }

    @Test func readDoesNotReplaceVisibleWrite() {
        let editor = EditorViewModel()
        editor.showAgentChanges(addedClipIds: ["clip"], mutatedClipIds: [])

        let read = editor.beginAgentTimelineRead(AgentActivityHighlight(readClipIds: ["clip"]))

        #expect(read == nil)
        #expect(editor.agentActivity.addedClipIds == ["clip"])
        editor.clearAgentActivity()
    }

    @Test func readRoutingDoesNotPreemptToolValidation() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("get_multicam", args: [
            "groupId": "missing",
            "startFrame": 20,
            "endFrame": 10,
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("No multicam group"))
    }

    @Test func readLifecycleIgnoresOverlapAndClearsErrors() throws {
        let editor = EditorViewModel()
        let first = try #require(editor.beginAgentTimelineRead(
            AgentActivityHighlight(readClipIds: ["first"])
        ))
        #expect(editor.agentActivity.isActive)

        let second = try #require(editor.beginAgentTimelineRead(
            AgentActivityHighlight(readClipIds: ["second"])
        ))
        editor.endAgentTimelineRead(first, succeeded: true)
        #expect(editor.agentActivity.readClipIds == ["second"])
        #expect(editor.agentActivity.isActive)

        editor.endAgentTimelineRead(second, succeeded: false)
        #expect(editor.agentActivity.isEmpty)

        let third = try #require(editor.beginAgentTimelineRead(
            AgentActivityHighlight(range: 10..<20)
        ))
        editor.endAgentTimelineRead(third, succeeded: true)
        #expect(editor.agentActivity.range == 10..<20)
        #expect(!editor.agentActivity.isActive)
        editor.clearAgentActivity()
    }

    @Test func windowedTimelineReadFadesAfterSuccess() async throws {
        let (harness, _) = harnessWithClip()
        _ = try await harness.runOK("get_timeline", args: [
            "startFrame": 10,
            "endFrame": 20,
        ])

        #expect(harness.editor.agentActivity.range == 10..<20)
        #expect(!harness.editor.agentActivity.isActive)
        harness.editor.clearAgentActivity()
    }

    @Test func timelineTracksNonAgentMutationInterleaving() {
        let editor = EditorViewModel()
        let initialRevision = editor.nonAgentTimelineMutationRevision
        editor.timeline.tracks = [Fixtures.videoTrack()]
        #expect(editor.nonAgentTimelineMutationRevision == initialRevision + 1)

        let revision = editor.nonAgentTimelineMutationRevision
        Analytics.$origin.withValue(.init(source: "agent", sessionID: "test")) {
            editor.timeline.tracks.append(Fixtures.audioTrack())
        }
        #expect(editor.nonAgentTimelineMutationRevision == revision)
    }

    @Test func highlightTimingsMatchActivityType() {
        #expect(AppTheme.Anim.agentChangeHighlightHold == 1.0)
        #expect(AppTheme.Anim.agentChangeHighlightFade == 0.3)
        #expect(abs(AppTheme.Anim.agentChangeHighlightDuration - 1.3) < 0.0001)
        #expect(AppTheme.Anim.agentReadHighlightHold == 0.7)
        #expect(AppTheme.Anim.agentReadHighlightFade == 0.25)
        #expect(abs(AppTheme.Anim.agentReadHighlightDuration - 0.95) < 0.0001)
    }

    @Test func classifiesFiveThousandClipRipple() {
        let clips = (0..<5_000).map {
            Fixtures.clip(id: "clip-\($0)", start: $0 * 10, duration: 10)
        }
        let before = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)])
        var after = before
        for index in after.tracks[0].clips.indices {
            after.tracks[0].clips[index].startFrame += 5
        }
        let harness = ToolHarness(timeline: before)
        harness.executor.publishAgentChanges(
            before: before,
            after: after,
            editor: harness.editor
        )
        #expect(harness.editor.agentActivity.mutatedClipIds.count == 5_000)
        harness.editor.clearAgentActivity()
    }

    @Test func writePrecedenceCoalescesAndTimelineSwitchClears() {
        let editor = EditorViewModel()
        editor.showAgentChanges(addedClipIds: ["clip"], mutatedClipIds: [])
        editor.showAgentChanges(
            addedClipIds: [],
            mutatedClipIds: ["clip", "other"],
            mutatedTrackIds: ["track"]
        )
        #expect(editor.agentActivity.addedClipIds == ["clip"])
        #expect(editor.agentActivity.mutatedClipIds == ["other"])
        #expect(editor.agentActivity.mutatedTrackIds == ["track"])

        let nextTimeline = Fixtures.timeline()
        editor.timelines.append(nextTimeline)
        editor.activateTimeline(nextTimeline.id)
        #expect(editor.agentActivity.isEmpty)
    }
}
