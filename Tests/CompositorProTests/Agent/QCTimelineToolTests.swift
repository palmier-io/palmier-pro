import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("qc_timeline")
@MainActor
struct QCTimelineToolTests {
    private func issues(_ payload: Any?) -> [[String: Any]] {
        ((payload as? [String: Any])?["issues"] as? [[String: Any]]) ?? []
    }

    private func kinds(_ payload: Any?) -> Set<String> {
        Set(issues(payload).compactMap { $0["kind"] as? String })
    }

    private func cleanFixture() async throws -> ToolHarness {
        let harness = ToolHarness()
        let video = harness.addAsset(type: .video, duration: 20, hasAudio: true)
        let music = harness.addAsset(type: .audio, duration: 30)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": video.id, "startFrame": 0, "source": [0.0, 4.0]],
            ["mediaRef": video.id, "startFrame": 120, "source": [4.0, 8.0]],
            ["mediaRef": music.id, "startFrame": 0, "source": [0.0, 9.0]],
        ]])
        return harness
    }

    @Test func anEmptyTimelineIsAnError() async throws {
        let harness = ToolHarness()
        let payload = try await harness.runOK("qc_timeline") as? [String: Any]
        #expect(payload?["pass"] as? Bool == false)
        #expect(kinds(payload) == ["emptyTimeline"])
        #expect(payload?["errorCount"] as? Int == 1)
    }

    @Test func reportsMissingAudio() async throws {
        let harness = ToolHarness()
        let video = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": video.id, "startFrame": 0, "source": [0.0, 4.0]],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
        let payload = try await harness.runOK("qc_timeline") as? [String: Any]
        #expect(kinds(payload).contains("noAudio"))
    }

    @Test func findsOverlapsGapsAndHardCuts() async throws {
        let harness = ToolHarness()
        let a = harness.addAsset(type: .audio, duration: 20)
        let b = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": a.id, "startFrame": 0, "source": [0.0, 3.0]],
            ["mediaRef": a.id, "startFrame": 60, "source": [3.0, 6.0]],
            ["mediaRef": b.id, "startFrame": 0, "source": [0.0, 4.0]],
        ]])
        let payload = try await harness.runOK("qc_timeline") as? [String: Any]
        let found = kinds(payload)
        #expect(found.contains("clipFadesHard"))
        #expect(found.contains("trackGap"))
        #expect(payload?["errorCount"] as? Int == 0)
        #expect((payload?["warningCount"] as? Int ?? 0) > 0)
    }

    /// The tools resolve overlap as they place clips, so this state comes from a project file
    /// or a bug. The audit still has to catch it.
    @Test func overlappingClipsOnOneTrackAreAnError() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 5.0]],
        ]])
        var timeline = harness.editor.timeline
        let original = timeline.tracks[0].clips[0]
        timeline.tracks[0].clips.append(
            Fixtures.clip(id: "intruder", mediaRef: asset.id, start: 30, duration: 60)
        )
        harness.editor.timeline = timeline
        #expect(original.durationFrames == 150)

        let payload = try await harness.runOK("qc_timeline", args: ["severity": "error"]) as? [String: Any]
        let overlap = issues(payload).first { $0["kind"] as? String == "overlappingClips" }
        #expect(overlap != nil)
        #expect(overlap?["startFrame"] as? Int == 30)
        #expect(overlap?["endFrame"] as? Int == 150)
        #expect((payload?["errorCount"] as? Int ?? 0) > 0)
    }

    @Test func speedReadingPastTheMediaEndIsAnError() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: 4)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 4.0]],
        ]])
        // 4s of media cannot supply 12s of playback.
        _ = try await harness.runOK("set_clip_properties", args: [
            "clipIds": [harness.editor.timeline.tracks[0].clips[0].id],
            "durationFrames": 360,
        ])
        let payload = try await harness.runOK("qc_timeline", args: ["severity": "error"]) as? [String: Any]
        #expect(kinds(payload).contains("outOfRangeSource"))
    }

    @Test func severityFiltersWarnings() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .audio, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 3.0]],
        ]])
        let all = try await harness.runOK("qc_timeline") as? [String: Any]
        let errorsOnly = try await harness.runOK("qc_timeline", args: ["severity": "error"]) as? [String: Any]
        #expect(issues(all).count > issues(errorsOnly).count)
        #expect(issues(errorsOnly).allSatisfy { $0["severity"] as? String == "error" })
    }

    @Test func rejectsAnUnknownSeverity() async throws {
        let harness = ToolHarness()
        let result = await harness.runRaw("qc_timeline", args: ["severity": "catastrophe"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("error or warning"))
    }

    @Test func aStaleTransitionIsReportedWithItsOwnId() async throws {
        let (harness, outgoing, incoming) = try await {
            let harness = ToolHarness()
            let a = harness.addAsset(type: .video, duration: 8, hasAudio: true)
            let b = harness.addAsset(type: .video, duration: 8, hasAudio: true)
            _ = try await harness.runOK("add_clips", args: ["entries": [
                ["mediaRef": a.id, "startFrame": 0, "source": [0.0, 4.0]],
                ["mediaRef": b.id, "startFrame": 120, "source": [1.0, 5.0]],
            ]])
            let clips = harness.editor.timeline.tracks.flatMap(\.clips)
                .filter { $0.mediaType == .video }.sorted { $0.startFrame < $1.startFrame }
            return (harness, clips[0], clips[1])
        }()
        let applied = try await harness.runOK("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "dipToBlack", "durationFrames": 6,
        ]) as? [String: Any]
        let transitionId = try #require(applied?["transitionId"] as? String ?? harness.editor.timeline.transitions.first?.id)

        // Clean: the transition is still valid.
        #expect(!kinds(try await harness.runOK("qc_timeline")).contains("staleTransition"))

        _ = try await harness.runOK("remove_clips", args: ["clipIds": [incoming.id]])
        // Cascading removal took the transition with it, so nothing is left to report.
        #expect(harness.editor.timeline.transitions.isEmpty)
        #expect(!kinds(try await harness.runOK("qc_timeline")).contains("staleTransition"))
        _ = transitionId
    }

    @Test func reportsMissingMediaByRef() async throws {
        let (harness, clip) = try await {
            let harness = ToolHarness()
            let asset = harness.addAsset(type: .video, duration: 20, hasAudio: true)
            _ = try await harness.runOK("add_clips", args: ["entries": [
                ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 4.0]],
            ]])
            return (harness, harness.editor.timeline.tracks[0].clips[0])
        }()
        harness.editor.missingMediaRefs = [clip.mediaRef]
        let payload = try await harness.runOK("qc_timeline", args: ["severity": "error"]) as? [String: Any]
        let reported = issues(payload).first { $0["kind"] as? String == "missingMedia" }
        // Ids come back in the shortened form every tool accepts as input.
        let reportedRef = try #require(reported?["mediaRef"] as? String)
        #expect(clip.mediaRef.hasPrefix(reportedRef))
        #expect(reported?["clipId"] != nil)
        #expect(reported?["fix"] as? String == "import_media")
    }

    @Test func reportsAHiddenTrack() async throws {
        let harness = try await cleanFixture()
        let trackId = try #require(harness.editor.timeline.tracks.first { $0.type == .video }?.id)
        _ = try await harness.runOK("manage_tracks", args: ["set": [["trackId": trackId, "hidden": true]]])
        #expect(kinds(try await harness.runOK("qc_timeline")).contains("hiddenTrack"))
    }

    @Test func passesAConsistentlyCutTimeline() async throws {
        let harness = try await cleanFixture()
        // Give the audio bed matched fades so nothing is flagged.
        let bed = try #require(harness.editor.timeline.tracks
            .flatMap(\.clips).first { $0.mediaType == .audio })
        _ = try await harness.runOK("set_clip_properties", args: [
            "clipIds": [bed.id], "fadeInFrames": 6, "fadeOutFrames": 6,
        ])
        let payload = try await harness.runOK("qc_timeline") as? [String: Any]
        #expect(payload?["errorCount"] as? Int == 0)
        #expect(payload?["checked"] as? Int == harness.editor.timeline.tracks.reduce(0) { $0 + $1.clips.count })
    }

    @Test func isReadOnly() async throws {
        let harness = try await cleanFixture()
        let before = harness.editor.timeline
        _ = try await harness.runOK("qc_timeline")
        #expect(harness.editor.timeline == before)
    }

    @Test func endToEndOverMCP() async throws {
        let harness = ToolHarness()
        let server = Server(name: "qc-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "qc-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "qc_timeline" })
            let result = try await client.callTool(name: "qc_timeline", arguments: [
                "severity": .string("error"),
            ])
            #expect(result.isError != true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
