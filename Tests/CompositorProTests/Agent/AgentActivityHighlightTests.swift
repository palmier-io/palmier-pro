import Foundation
import Testing
@testable import CompositorPro

@Suite("Agent activity highlights")
@MainActor
struct AgentActivityHighlightTests {
    private func harnessWithClip(duration: Int = 100) -> (ToolHarness, Clip) {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: duration)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        return (ToolHarness(timeline: timeline), clip)
    }

    private func holdActivityExpiry(
        in editor: EditorViewModel,
        cooperatesWithCancellation: Bool = true
    ) -> AgentActivitySleepGate {
        let gate = AgentActivitySleepGate(cooperatesWithCancellation: cooperatesWithCancellation)
        editor.agentActivitySleep = { try await gate.sleep(for: $0) }
        return gate
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
        let gate = holdActivityExpiry(in: harness.editor)
        defer { harness.editor.clearAgentActivity(); gate.cancelAll() }
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
        let gate = holdActivityExpiry(in: harness.editor)
        defer { harness.editor.clearAgentActivity(); gate.cancelAll() }
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
        let gate = holdActivityExpiry(in: harness.editor)
        defer { harness.editor.clearAgentActivity(); gate.cancelAll() }

        _ = try await harness.runOK("manage_tracks", args: [
            "reorder": [["index": 0, "to": 1]],
            "set": [
                ["index": 0, "hidden": true, "syncLocked": false],
                ["index": 2, "muted": true],
            ],
        ])

        #expect(harness.editor.agentActivity.mutatedTrackIds == [first.id, second.id, audio.id])
        harness.editor.clearAgentActivity()

        _ = try await harness.runOK("manage_tracks", args: [
            "set": [["trackId": second.id, "name": "B-roll"]],
        ])
        #expect(harness.editor.agentActivity.mutatedTrackIds == [second.id])
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
        let gate = holdActivityExpiry(in: harness.editor)
        defer { harness.editor.clearAgentActivity(); gate.cancelAll() }
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

    @Test(arguments: [false, true])
    func completedActivityExpiresOnlyAfterSleepFinishes(isRead: Bool) async throws {
        let editor = EditorViewModel()
        let gate = holdActivityExpiry(in: editor)
        defer { editor.clearAgentActivity(); gate.cancelAll() }
        if isRead {
            let revision = try #require(editor.beginAgentTimelineRead(
                AgentActivityHighlight(readClipIds: ["clip"])
            ))
            #expect(editor.agentActivity.isActive)
            #expect(editor.agentActivityClearTask == nil)
            #expect(gate.durations.isEmpty)
            editor.endAgentTimelineRead(revision, succeeded: true)
        } else {
            editor.showAgentChanges(addedClipIds: ["clip"], mutatedClipIds: [])
        }
        let task = try #require(editor.agentActivityClearTask)
        let activity = editor.agentActivity
        await gate.waitForSleeps(1)

        let duration = isRead
            ? AppTheme.Anim.agentReadHighlightDuration
            : AppTheme.Anim.agentChangeHighlightDuration
        #expect(gate.durations == [.seconds(duration)])
        #expect(editor.agentActivity == activity)
        #expect(!editor.agentActivity.isEmpty)
        #expect(!editor.agentActivity.isActive)

        gate.finishSleep(0)
        await task.value

        #expect(editor.agentActivity.isEmpty)
        #expect(editor.agentActivity.revision == activity.revision &+ 1)
        #expect(editor.agentActivityClearTask == nil)
        #expect(gate.pendingSleepCount == 0)
    }

    @Test(arguments: ["write-write", "read-write", "read-read"])
    func replacedActivityIgnoresCancelledSleepCompletion(replacement: String) async throws {
        let editor = EditorViewModel()
        let gate = holdActivityExpiry(in: editor, cooperatesWithCancellation: false)
        defer { editor.clearAgentActivity(); gate.cancelAll() }
        if replacement == "write-write" {
            editor.showAgentChanges(addedClipIds: ["first"], mutatedClipIds: [])
        } else {
            let revision = try #require(editor.beginAgentTimelineRead(
                AgentActivityHighlight(readClipIds: ["first"])
            ))
            editor.endAgentTimelineRead(revision, succeeded: true)
        }
        let firstTask = try #require(editor.agentActivityClearTask)
        await gate.waitForSleeps(1)

        var readRevision: Int?
        if replacement == "read-read" {
            readRevision = try #require(editor.beginAgentTimelineRead(
                AgentActivityHighlight(readClipIds: ["second"])
            ))
            #expect(editor.agentActivityClearTask == nil)
        } else {
            editor.showAgentChanges(addedClipIds: ["second"], mutatedClipIds: [])
            let expected: Set<String> = replacement == "write-write" ? ["first", "second"] : ["second"]
            #expect(editor.agentActivity.addedClipIds == expected)
        }
        let replacementActivity = editor.agentActivity
        #expect(firstTask.isCancelled)

        gate.finishSleep(0)
        await firstTask.value

        #expect(editor.agentActivity == replacementActivity)
        if let readRevision {
            #expect(editor.agentActivity.isActive)
            editor.endAgentTimelineRead(readRevision, succeeded: true)
        }
        let secondTask = try #require(editor.agentActivityClearTask)
        await gate.waitForSleeps(2)
        gate.finishSleep(1)
        await secondTask.value
        #expect(editor.agentActivity.isEmpty)
        #expect(editor.agentActivityClearTask == nil)
        #expect(gate.pendingSleepCount == 0)
    }

    @Test(arguments: ["clear", "timeline"])
    func clearingActivityCancelsPendingSleep(action: String) async throws {
        let editor = EditorViewModel()
        let gate = holdActivityExpiry(in: editor)
        defer { editor.clearAgentActivity(); gate.cancelAll() }
        editor.showAgentChanges(addedClipIds: ["clip"], mutatedClipIds: [])
        let task = try #require(editor.agentActivityClearTask)
        await gate.waitForSleeps(1)

        if action == "timeline" {
            let timeline = Fixtures.timeline()
            editor.timelines.append(timeline)
            editor.activateTimeline(timeline.id)
        } else {
            editor.clearAgentActivity()
        }
        let clearedActivity = editor.agentActivity
        #expect(clearedActivity.isEmpty)
        #expect(editor.agentActivityClearTask == nil)
        #expect(task.isCancelled)
        await task.value
        #expect(gate.pendingSleepCount == 0)
        #expect(editor.agentActivity == clearedActivity)

        editor.clearAgentActivity()
        #expect(editor.agentActivity == clearedActivity)
    }

    @Test func cancellationBeforeSleepStartsDoesNotAdmitWaiter() async throws {
        let editor = EditorViewModel()
        let gate = holdActivityExpiry(in: editor)
        defer { editor.clearAgentActivity(); gate.cancelAll() }
        editor.showAgentChanges(addedClipIds: ["clip"], mutatedClipIds: [])
        let task = try #require(editor.agentActivityClearTask)
        editor.clearAgentActivity()
        let clearedActivity = editor.agentActivity

        await task.value

        #expect(gate.durations.isEmpty)
        #expect(gate.pendingSleepCount == 0)
        #expect(editor.agentActivity == clearedActivity)
        #expect(editor.agentActivityClearTask == nil)
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

@MainActor
private final class AgentActivitySleepGate {
    private let cooperatesWithCancellation: Bool
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var sleepIds: [UUID] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var durations: [Duration] = []

    var pendingSleepCount: Int { sleepers.count }

    init(cooperatesWithCancellation: Bool) {
        self.cooperatesWithCancellation = cooperatesWithCancellation
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = continuation
                sleepIds.append(id)
                durations.append(duration)
                let ready = observers.filter { $0.0 <= durations.count }
                observers.removeAll { $0.0 <= durations.count }
                for (_, observer) in ready { observer.resume() }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.cooperatesWithCancellation else { return }
                self.sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func waitForSleeps(_ count: Int) async {
        if durations.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func finishSleep(_ index: Int) {
        guard sleepIds.indices.contains(index),
              let sleeper = sleepers.removeValue(forKey: sleepIds[index]) else {
            Issue.record("No pending activity sleep at index \(index).")
            return
        }
        sleeper.resume()
    }

    func cancelAll() {
        let pending = sleepers.values
        sleepers.removeAll()
        for sleeper in pending { sleeper.resume(throwing: CancellationError()) }
        let waiting = observers
        observers.removeAll()
        for (_, observer) in waiting { observer.resume() }
    }
}
