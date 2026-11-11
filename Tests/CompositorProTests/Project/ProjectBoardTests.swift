import Foundation
import Testing
@testable import CompositorPro

@Suite("Project board derivation")
struct ProjectBoardTests {
    @Test func emptyTimelineGeneratesPendingStages() {
        let dummyURL = URL(fileURLWithPath: "/tmp/test-project.compositorpro")
        let timeline = Timeline(id: "tl1", name: "Empty", fps: 30, width: 1920, height: 1080)
        let summary = ProjectBoard.summary(projectURL: dummyURL, timeline: timeline)

        #expect(summary.projectId == "test-project")
        #expect(summary.name == "test-project")
        #expect(summary.clipCount == 0)
        #expect(summary.durationSeconds == 0)
        #expect(!summary.stalled)
        #expect(summary.stageRail.count == 4)
        #expect(summary.stageRail.allSatisfy { $0.status == "pending" })
    }

    @Test func populatedTimelinePopulatesStages() {
        let dummyURL = URL(fileURLWithPath: "/tmp/active-project.compositorpro")
        var videoTrack = Track(id: "v1", type: .video, name: "Video")
        videoTrack.clips.append(Fixtures.clip(id: "c1", start: 0, duration: 90))

        var audioTrack = Track(id: "a1", type: .audio, name: "Audio")
        audioTrack.clips.append(Fixtures.clip(id: "c2", mediaType: .audio, start: 0, duration: 90))

        var textTrack = Track(id: "t1", type: .subtitle, name: "Captions")
        textTrack.clips.append(Fixtures.clip(id: "c3", mediaType: .subtitle, start: 0, duration: 90))

        let timeline = Timeline(id: "tl2", name: "Active", fps: 30, width: 1920, height: 1080, tracks: [videoTrack, audioTrack, textTrack])
        let summary = ProjectBoard.summary(projectURL: dummyURL, timeline: timeline)

        #expect(summary.clipCount == 3)
        #expect(summary.durationSeconds == 3.0)
        #expect(summary.stageRail.allSatisfy { $0.status == "completed" })
    }

    @Test func scansMediaFilesInProjectDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let renderURL = tempDir.appendingPathComponent("export.mp4")
        let snapshotURL = tempDir.appendingPathComponent("thumb.png")
        let audioURL = tempDir.appendingPathComponent("music.wav")
        try "dummy render".write(to: renderURL, atomically: true, encoding: .utf8)
        try "dummy snap".write(to: snapshotURL, atomically: true, encoding: .utf8)
        try "dummy audio".write(to: audioURL, atomically: true, encoding: .utf8)

        let timeline = Timeline(id: "tl3", name: "Media", fps: 30, width: 1920, height: 1080)
        let summary = ProjectBoard.summary(projectURL: tempDir, timeline: timeline)

        #expect(summary.media.renders.contains("export.mp4"))
        #expect(summary.media.snapshots.contains("thumb.png"))
        #expect(summary.media.audio.contains("music.wav"))
        #expect(summary.media.renderCount == 1)
    }
}
