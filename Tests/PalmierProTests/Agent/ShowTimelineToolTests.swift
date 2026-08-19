import Foundation
import Testing
@testable import PalmierPro

@MainActor
struct ShowTimelineToolTests {
    @Test func emptyTimelineIsRejected() async {
        let harness = ToolHarness()
        let result = await harness.runRaw("show_timeline")
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).localizedCaseInsensitiveContains("empty"))
    }

    @Test func unknownTimelineIdIsRejected() async {
        let clip = Fixtures.clip(start: 0, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        defer { harness.executor.timelinePreviewRenderTask?.cancel() }
        let result = await harness.runRaw("show_timeline", args: ["timelineId": "missing-timeline-id"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).localizedCaseInsensitiveContains("no timeline"))
    }

    @Test func windowCapsLongTimelinesAndReportsTheSpan() throws {
        let window = try ToolExecutor.timelinePreviewWindow(
            totalFrames: 30 * 60,
            fps: 30,
            startFrame: 0,
            endFrame: nil
        )
        #expect(window.startFrame == 0)
        #expect(window.endFrame == 30 * ToolExecutor.timelinePreviewMaxSeconds)
        #expect(window.windowed)
    }

    @Test func requestedRangeIsPreservedWhenShort() throws {
        let window = try ToolExecutor.timelinePreviewWindow(
            totalFrames: 900,
            fps: 30,
            startFrame: 90,
            endFrame: 150
        )
        #expect(window.startFrame == 90)
        #expect(window.endFrame == 150)
        #expect(!window.windowed)
    }

    @Test func aspectRatioUsesLowestTerms() {
        #expect(ToolExecutor.aspectRatioLabel(width: 1920, height: 1080) == "16:9")
        #expect(ToolExecutor.aspectRatioLabel(width: 1080, height: 1920) == "9:16")
    }

    @Test func returnsGeneratingReceiptForActiveTimeline() async throws {
        let clip = Fixtures.clip(start: 0, duration: 45)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.name = "Variant A"
        let harness = ToolHarness(timeline: timeline)
        defer { harness.executor.timelinePreviewRenderTask?.cancel() }

        let payload = try await harness.runOK("show_timeline") as? [String: Any]
        #expect(payload?["kind"] as? String == "timeline")
        #expect(payload?["status"] as? String == "generating")
        #expect(payload?["timelineName"] as? String == "Variant A")
        let timelineId = try #require(payload?["timelineId"] as? String)
        #expect(harness.editor.activeTimelineId.hasPrefix(timelineId))
        #expect((payload?["mediaRef"] as? String)?.isEmpty == false)
    }

    @Test func multipleTimelineIdsShareOneGroup() async throws {
        let clip = Fixtures.clip(start: 0, duration: 30)
        var first = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        first.name = "A"
        let harness = ToolHarness(timeline: first)
        defer { harness.executor.timelinePreviewRenderTask?.cancel() }
        let secondId = harness.editor.createTimeline(name: "B")
        harness.editor.timeline = {
            var copy = harness.editor.timeline
            copy.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])]
            return copy
        }()

        let payload = try await harness.runOK("show_timeline", args: [
            "timelineIds": [first.id, secondId],
        ]) as? [String: Any]
        let members = payload?["groupMembers"] as? [String]
        #expect(members?.count == 2)
        #expect(payload?["kind"] as? String == "timeline")
        let previews = payload?["previews"] as? [[String: Any]]
        #expect(previews?.count == 2)
        let names = Set(previews?.compactMap { $0["timelineName"] as? String } ?? [])
        #expect(names == ["A", "B"])
    }

    @Test func consecutiveVideoGensShareOneBurst() {
        let harness = ToolHarness()
        let first = harness.executor.registerMCPPreviewBurst(kind: "video", mediaRef: "v1")
        #expect(first.role == "host")
        #expect(first.members == ["v1"])
        let second = harness.executor.registerMCPPreviewBurst(kind: "video", mediaRef: "v2")
        #expect(second.role == "member")
        #expect(second.members == ["v1", "v2"])
        #expect(harness.executor.mcpPreviewGroup(for: "v1")?.role == "host")
        #expect(harness.executor.mcpPreviewGroup(for: "v1")?.members == ["v1", "v2"])
        let image = harness.executor.registerMCPPreviewBurst(kind: "image", mediaRef: "i1")
        #expect(image.role == "host")
        #expect(image.members == ["i1"])
    }

    @Test func audioDoesNotJoinAVideoBurst() {
        let harness = ToolHarness()
        _ = harness.executor.registerMCPPreviewBurst(kind: "video", mediaRef: "v1")
        let audio = harness.executor.registerMCPPreviewBurst(kind: "audio", mediaRef: "a1")
        #expect(audio.role == "host")
        #expect(audio.members == ["a1"])
    }
}
