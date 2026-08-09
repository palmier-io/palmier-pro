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

    @Test func onlyMutationToolsPublishTimelineChanges() {
        let excluded: [ToolName] = [.inspectTimeline, .getTranscript, .manageTracks, .organizeMedia]
        let included: [ToolName] = [.setClipProperties, .denoiseAudio, .generateAudio]
        #expect(excluded.allSatisfy { !$0.publishesTimelineChanges })
        #expect(included.allSatisfy { $0.publishesTimelineChanges })
    }

    @Test func mapsOnlyVisibleTimelineReads() throws {
        let (harness, clip) = harnessWithClip()
        func activity(
            _ tool: ToolName,
            _ args: [String: Any] = [:]
        ) throws -> AgentActivityHighlight? {
            try harness.executor.timelineReadActivity(for: tool, args: args, editor: harness.editor)
        }

        let clipActivity = try activity(.inspectMedia, ["clipId": clip.id])
        let clipRead = try #require(clipActivity)
        #expect(clipRead.readClipIds == [clip.id])

        let combinedActivity = try activity(.getTranscript, [
            "clipId": clip.id,
            "startFrame": 10,
            "endFrame": 20,
        ])
        let combinedRead = try #require(combinedActivity)
        #expect(combinedRead.readClipIds == [clip.id])
        #expect(combinedRead.range == 10..<20)

        let excludedReads = try [
            activity(.getMedia),
            activity(.getTimeline),
            activity(.getTimeline, ["startFrame": 0, "endFrame": 0]),
            activity(.inspectTimeline, ["startFrame": Int.max]),
            activity(.getTimeline, ["startFrame": 1_000, "endFrame": 2_000]),
        ]
        #expect(excludedReads.allSatisfy { $0 == nil })
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

    @Test func classifiesFiveThousandClipRippleWithinInteractiveBudget() {
        let clips = (0..<5_000).map {
            Fixtures.clip(id: "clip-\($0)", start: $0 * 10, duration: 10)
        }
        let before = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)])
        var after = before
        for index in after.tracks[0].clips.indices {
            after.tracks[0].clips[index].startFrame += 5
        }
        let harness = ToolHarness(timeline: before)
        let elapsed = ContinuousClock().measure {
            harness.executor.publishAgentChanges(
                before: before,
                after: after,
                editor: harness.editor
            )
        }

        print("5,000-clip Agent highlight classification: \(elapsed)")
        #expect(harness.editor.agentActivity.mutatedClipIds.count == 5_000)
        #expect(elapsed < .milliseconds(100))
        harness.editor.clearAgentActivity()
    }

    @Test func writePrecedenceCoalescesAndTimelineSwitchClears() {
        let editor = EditorViewModel()
        editor.showAgentChanges(addedClipIds: ["clip"], mutatedClipIds: [])
        editor.showAgentChanges(addedClipIds: [], mutatedClipIds: ["clip", "other"])
        #expect(editor.agentActivity.addedClipIds == ["clip"])
        #expect(editor.agentActivity.mutatedClipIds == ["other"])

        let nextTimeline = Fixtures.timeline()
        editor.timelines.append(nextTimeline)
        editor.activateTimeline(nextTimeline.id)
        #expect(editor.agentActivity.isEmpty)
    }
}
